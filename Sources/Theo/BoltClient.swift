import Foundation
import PackStream
import Bolt
import Result
import Socket

#if os(Linux)
import Dispatch
#endif

public struct QueryWithParameters {
    let query: String
    let parameters: Dictionary<String,Any>
}

public class Transaction {

    public var succeed: Bool = true
    public var bookmark: String? = nil
    public var autocommit: Bool = true
    internal var commitBlock: (Bool) throws -> Void = { _ in }

    public init() {
    }

    public func markAsFailed() {
        succeed = false
    }
}

private struct InMemoryClientConfiguration: ClientConfigurationProtocol {
    let hostname: String
    let port: Int
    let username: String
    let password: String
    let encrypted: Bool
    let poolSize: ClosedRange<UInt>

}

private class ConnectionsWithProperties {
    let connection: Connection
    var inUse: Bool
    
    init(connection: Connection) {
        self.connection = connection
        self.inUse = false
    }
}

typealias BoltRequest = Bolt.Request

open class BoltClient {

    private let configuration: ClientConfigurationProtocol
    
    private var hostname: String { return configuration.hostname }
    private var port: Int { return configuration.port }
    private var username: String { return configuration.username }
    private var password: String { return configuration.password }
    private var encrypted: Bool { return configuration.encrypted }
    
    private var connections: [ConnectionsWithProperties]
    private let connectionSemaphore: DispatchSemaphore

    private var currentTransaction: Transaction?

    public enum BoltClientError: Error {
        case missingNodeResponse
        case missingRelationshipResponse
        case queryUnsuccessful
        case unexpectedNumberOfResponses
        case fetchingRecordsUnsuccessful
        case couldNotCreateRelationship
        case unknownError
    }

    required public init(_ configuration: ClientConfigurationProtocol) throws {

        self.configuration = configuration


        let semaphoreValue: Int = configuration.poolSize.upperBound
        print("semaphoreValue: \(semaphoreValue)")
        self.connectionSemaphore = DispatchSemaphore(value: semaphoreValue)
        self.connections = []
        self.connections = try (0..<configuration.poolSize.lowerBound).map { _ in
            return try self.generateConnectionWithProperties()
        }
    }
    
    private func generateConnectionWithProperties() throws -> ConnectionsWithProperties {
        let noConfig = SSLConfiguration(json: [:])
        let sslConfiguration = EncryptedSocket.defaultConfiguration(sslConfig: noConfig,
                                                                    allowHostToBeSelfSigned: true)

        let settings = ConnectionSettings(
            username: self.configuration.username,
            password: self.configuration.password,
            userAgent: "Theo 4.1.0")

        let socket = try EncryptedSocket(
            hostname: configuration.hostname,
            port: configuration.port,
            configuration: sslConfiguration)
        
        let connection = Connection(
            socket: socket,
            settings: settings)
        
        return ConnectionsWithProperties(connection: connection)
    }

    required public convenience init(
        hostname: String = "localhost",
        port: Int = 7687,
        username: String = "neo4j",
        password: String = "neo4j",
        encrypted: Bool = true,
        poolSize: ClosedRange<UInt> = 1...1) throws {
        
        let configuration = InMemoryClientConfiguration(
            hostname: hostname,
            port: port,
            username: username,
            password: password,
            encrypted: encrypted,
            poolSize: poolSize)
        try self.init(configuration)
    }

    /**
     Connects to Neo4j given the connection settings BoltClient was initialized with.

     Asynchronous, so the function returns straight away. It is not defined what thread the completionblock will run on,
     so if you need it to run on main thread or another thread, make sure to dispatch to this that thread

     - parameter connection: The connection that should connect
     - parameter completionBlock: Completion result-block that provides a Bool to indicate success, or an Error to explain what went wrong
     */
    public func connect(connection: Connection, completionBlock: ((Result<Bool, AnyError>) -> ())? = nil) {

        do {
            try connection.connect { (connected) in
                completionBlock?(.success(connected))
            }
        } catch let error as Socket.Error {
            completionBlock?(.failure(AnyError(error)))
        } catch let error as Connection.ConnectionError {
            completionBlock?(.failure(AnyError(error)))
        } catch let error {
            print("Unknown error while connecting: \(error.localizedDescription)")
            completionBlock?(.failure(AnyError(error)))
        }
    }

    /**
     Connects to Neo4j given the connection settings BoltClient was initialized with.

     Synchronous, so the function will return only when the connection attempt has been made.

     - returns: Result that provides a Bool to indicate success, or an Error to explain what went wrong
     */
    public func connectSync() -> Result<Bool, AnyError> {

        let connection = getConnection()
        var theResult: Result<Bool, AnyError>! = nil
        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        connect(connection: connection) { result in
            theResult = result
            dispatchGroup.leave()
        }
        dispatchGroup.wait()
        self.release(connection)
        return theResult
    }

    /**
     Disconnects from Neo4j.
     */
    // !!! Does this make sense anymore?
//    public func disconnect() {
//        connection.disconnect()
//    }
    
    private let connectionsMutationSemaphore = DispatchSemaphore(value: 1)

    /**
     * Get a connection to perform async operations upon. Remember to release it when you're done with it
     */
    public func getConnection() -> Connection {
        print("Get connection:")
        self.connectionSemaphore.wait()
        connectionsMutationSemaphore.wait()
        var connection: Connection? = nil
        var i = 0
        for alt in self.connections {
            if alt.inUse == false {
                alt.inUse = true
                connection = alt.connection
                self.connections[i] = alt
                break
            }
            
            i = i + 1
        }
        
        if connection == nil {
            let connectionWithProps = try! generateConnectionWithProperties() // !!!
            connectionWithProps.inUse = true
            self.connections.append(connectionWithProps)
            i = i + 1
            connection = connectionWithProps.connection
        }
        
        print("Got connection #\(i)")
        
        connectionsMutationSemaphore.signal()
        
        return connection! // !!!
        
    }
    
    /*
     * Release the open connection
     */
    public func release(_ connection: Connection) {
        connectionsMutationSemaphore.wait()
        var i = 0
        for alt in self.connections {
            if alt.connection == connection {
                alt.inUse = false
                self.connections[i] = alt
                break
            }
            i = i + 1
        }
        print("Released connection #\(i)")
        connectionsMutationSemaphore.signal()
        self.connectionSemaphore.signal()
    }

    /**
     Executes a given request on Neo4j

     Requires an established connection

     Asynchronous, so the function returns straight away. It is not defined what thread the completionblock will run on,
     so if you need it to run on main thread or another thread, make sure to dispatch to this that thread

     - warning: This function only performs a single request, and that request can lead Neo4j to expect a certain follow-up request, or disconnect with a failure if it receives an unexpected request following this request.

     - parameter request: The Bolt Request that will be sent to Neo4j
     - parameter completionBlock: Completion result-block that provides a partial QueryResult, or an Error to explain what went wrong
     */
    public func execute(connection: Connection, request: Request, completionBlock: ((Result<(Bool, QueryResult), AnyError>) -> ())? = nil) {
        
        do {
            try connection.request(request) { (successResponse, response) in
                let queryResponse = parseResponses(responses: response)
                completionBlock?(.success((successResponse, queryResponse)))
            }

        } catch let error as Socket.Error {
            completionBlock?(.failure(AnyError(error)))
        } catch let error as Response.ResponseError {
            completionBlock?(.failure(AnyError(error)))
        } catch let error {
            print("Unhandled error while executing cypher: \(error.localizedDescription)")
        }
    }

    /**
     Executes a given request on Neo4j, and pulls the respons data

     Requires an established connection

     Asynchronous, so the function returns straight away. It is not defined what thread the completionblock will run on,
     so if you need it to run on main thread or another thread, make sure to dispatch to this that thread

     - warning: This function should only be used with requests that expect data to be pulled after they run. Other requests can make Neo4j disconnect with a failure when it is subsequent asked for the result data

     - parameter request: The Bolt Request that will be sent to Neo4j
     - parameter completionBlock: Completion result-block that provides a complete QueryResult, or an Error to explain what went wrong
     */
    public func executeWithResult(request: Request, completionBlock: ((Result<(Bool, QueryResult), AnyError>) -> ())? = nil) {
        let connection = getConnection()
        do {
            try connection.request(request) { (successResponse, response) in
                if successResponse == false {
                    self.release(connection)
                    completionBlock?(.failure(AnyError(BoltClientError.queryUnsuccessful)))
                } else {
                    let queryResponse = parseResponses(responses: response)
                    self.pullAll(connection: connection, partialQueryResult: queryResponse) { result in
                        self.release(connection)
                        switch result {
                        case let .failure(error):
                            completionBlock?(.failure(AnyError(error)))
                        case let .success((successResponse, queryResponse)):
                            if successResponse == false {
                                completionBlock?(.failure(AnyError(BoltClientError.queryUnsuccessful)))
                            } else {
                                completionBlock?(.success((successResponse, queryResponse)))
                            }
                        }
                    }
                }
            }
        } catch let error as Socket.Error {
            completionBlock?(.failure(AnyError(error)))
        } catch let error as Response.ResponseError {
            completionBlock?(.failure(AnyError(error)))
        } catch let error {
            print("Unhandled error while executing cypher: \(error.localizedDescription)")
        }
    }

    /**
     Executes a given cypher query on Neo4j

     Requires an established connection

     Asynchronous, so the function returns straight away. It is not defined what thread the completionblock will run on,
     so if you need it to run on main thread or another thread, make sure to dispatch to this that thread

     - warning: Executing a query should be followed by a data pull with the response from Neo4j. Not doing so can lead to Neo4j closing the client connection.

     - parameter query: The Cypher query to be executed
     - parameter params: The named parameters to be included in the query. All parameter values need to conform to PackProtocol, as this is how they are encoded when sent via Bolt to Neo4j
     - parameter completionBlock: Completion result-block that provides a partial QueryResult, or an Error to explain what went wrong
     */
    public func executeCypher(_ query: String, params: Dictionary<String,PackProtocol>? = nil, connection: Connection, completionBlock: ((Result<(Bool, QueryResult), AnyError>) -> ())? = nil) {

        let cypherRequest = BoltRequest.run(statement: query, parameters: Map(dictionary: params ?? [:]))

        execute(connection: connection, request: cypherRequest, completionBlock: completionBlock)

    }

    /**
     Executes a given cypher query on Neo4j

     Requires an established connection

     Synchronous, so the function will return only when the query result is ready

     - parameter query: The Cypher query to be executed
     - parameter params: The named parameters to be included in the query. All parameter values need to conform to PackProtocol, as this is how they are encoded when sent via Bolt to Neo4j
     - returns: Result that provides a complete QueryResult, or an Error to explain what went wrong
     */
    @discardableResult
    public func executeCypherSync(_ query: String, params: Dictionary<String,PackProtocol>? = nil) -> (Result<QueryResult, AnyError>) {

        let connection = getConnection()
        var theResult: Result<QueryResult, AnyError>! = nil
        let dispatchGroup = DispatchGroup()

        // Perform query
        dispatchGroup.enter()
        var partialResult = QueryResult()
        executeCypher(query, params: params, connection: connection) { result in
            switch result {
            case let .failure(error):
                print("Error: \(error)")
                theResult = .failure(error)
            case let .success((isSuccess, _partialResult)):
                if isSuccess == false {
                    let error = AnyError(BoltClientError.queryUnsuccessful)
                    theResult = .failure(error)
                } else {
                    partialResult = _partialResult
                }
            }
            dispatchGroup.leave()
        }
        dispatchGroup.wait()
        if theResult != nil {
            return theResult
        }

        // Stream and parse results
        dispatchGroup.enter()
        pullAll(connection: connection, partialQueryResult: partialResult) { result in
            self.release(connection)

            switch result {
            case let .failure(error):
                print("Error: \(error)")
                theResult = .failure(error)
            case let .success(isSuccess, parsedResponses):
                if isSuccess == false {
                    let error = AnyError(BoltClientError.queryUnsuccessful)
                    theResult = .failure(error)
                } else {
                    theResult = .success(parsedResponses)
                }
            }

            dispatchGroup.leave()
        }

        dispatchGroup.wait()
        return theResult
    }



    private func parseResponses(responses: [Response], result: QueryResult = QueryResult()) -> QueryResult {
        let fields = (responses.flatMap { $0.items } .flatMap { ($0 as? Map)?.dictionary["fields"] }.first as? List)?.items.flatMap { $0 as? String }
        if let fields = fields {
            result.fields = fields
        }

        let stats = responses.flatMap { $0.items.flatMap { $0 as? Map }.flatMap { QueryStats(data: $0) } }.first
        if let stats = stats {
            result.stats = stats
        }

        if let resultAvailableAfter = (responses.flatMap { $0.items } .flatMap { ($0 as? Map)?.dictionary["result_available_after"] }.first?.uintValue()) {
            result.stats.resultAvailableAfter = resultAvailableAfter
        }

        if let resultConsumedAfter = (responses.flatMap { $0.items } .flatMap { $0 as? Map }.first?.dictionary["result_consumed_after"]?.uintValue()) {
            result.stats.resultConsumedAfter = resultConsumedAfter
        }

        if let type = (responses.flatMap { $0.items } .flatMap { $0 as? Map }.first?.dictionary["type"] as? String) {
            result.stats.type = type
        }



        let candidateList = responses.flatMap { $0.items.flatMap { ($0 as? List)?.items } }.reduce( [], +)
        var nodes = [UInt64:Node]()
        var relationships = [UInt64:Relationship]()
        var paths = [Path]()
        var rows = [[String:ResponseItem]]()
        var row = [String:ResponseItem]()

        for i in 0..<candidateList.count {
            if result.fields.count > 0, // there must be a field
               i > 0, // skip the first, because the  first row is already set
               i % result.fields.count == 0 { // then we need to break into the next row
                rows.append(row)
                row = [String:ResponseItem]()
            }

            let field = result.fields.count > 0 ? result.fields[i % result.fields.count] : nil
            let candidate = candidateList[i]

            if let node = Node(data: candidate) {
                if let nodeId = node.id {
                    nodes[nodeId] = node
                }

                if let field = field {
                    row[field] = node
                }
            }

            else if let relationship = Relationship(data: candidate) {
                if let relationshipId = relationship.id {
                    relationships[relationshipId] = relationship
                }

                if let field = field {
                    row[field] = relationship
                }
            }

            else if let path = Path(data: candidate) {
                paths.append(path)

                if let field = field {
                    row[field] = path
                }
            }

            else if let record = candidate.uintValue() {
                if let field = field {
                    row[field] = record
                }
            }

            else if let record = candidate.intValue() {
                if let field = field {
                    row[field] = record
                }
            }

            else if let record = candidate as? ResponseItem {
                if let field = field {
                    row[field] = record
                }
            }

            else {
                let record = Record(entry: candidate)
                if let field = field {
                    row[field] = record
                }
            }
        }

        if row.count > 0 {
            rows.append(row)
        }

        result.nodes.merge(nodes) { (n, _) -> Node in return n }

        let mapper: (UInt64, Relationship) -> (UInt64, Relationship)? = { (key: UInt64, rel: Relationship) in
            guard let fromNodeId = rel.fromNodeId, let toNodeId = rel.toNodeId else {
                print("Relationship was missing id in response. This is most unusual! Please report a bug!")
                return nil
            }
            rel.fromNode = nodes[fromNodeId]
            rel.toNode = nodes[toNodeId]
            return (key, rel)
        }

        let updatedRelationships = Dictionary(uniqueKeysWithValues: relationships.flatMap(mapper))
        result.relationships.merge(updatedRelationships) { (r, _) -> Relationship in return r }

        result.paths += paths
        result.rows += rows

        return result

    }


    /**
     Executes a given block, usually containing multiple cypher queries run and results processed, as a transaction

     Requires an established connection

     Synchronous, so the function will return only when the query result is ready

     - parameter bookamrk: If a transaction bookmark has been given, the Neo4j node will wait until it has received a transaction with that bookmark before this transaction is run. This ensures that in a multi-node setup, the expected queries have been run before this set is.
     - parameter transactionBlock: The block of queries and result processing that make up the transaction. The Transaction object is available to it, so that it can mark it as failed, disable autocommit (on by default), or, after the transaction has been completed, get the transaction bookmark.
     */
    public func executeAsTransaction(bookmark: String? = nil, transactionBlock: @escaping (_ tx: Transaction) throws -> ()) throws {

        let connection = getConnection()
        let transactionGroup = DispatchGroup()

        let transaction = Transaction()
        transaction.commitBlock = { succeed in
            if succeed {
                let commitRequest = BoltRequest.run(statement: "COMMIT", parameters: Map(dictionary: [:]))
                try connection.request(commitRequest) { (success, response) in
                    self.pullSynchronouslyAndIgnore(connection: connection)
                    if !success {
                        let error = BoltClientError.queryUnsuccessful
                        throw error
                    }
                    self.currentTransaction = nil
                    self.release(connection)
                    transactionGroup.leave()
                }
            } else {

                let rollbackRequest = BoltRequest.run(statement: "ROLLBACK", parameters: Map(dictionary: [:]))
                try connection.request(rollbackRequest) { (success, response) in
                    defer { self.release(connection) }
                    self.pullSynchronouslyAndIgnore(connection: connection)
                    if !success {
                        print("Error rolling back transaction: \(response)")
                        let error = BoltClientError.queryUnsuccessful
                        throw error
                    }
                    self.currentTransaction = nil
                    transactionGroup.leave()
                }
            }
        }

        currentTransaction = transaction

        let beginRequest = BoltRequest.run(statement: "BEGIN", parameters: Map(dictionary: [:]))

        transactionGroup.enter()

        try connection.request(beginRequest) { (success, response) in
            if success {

                pullSynchronouslyAndIgnore(connection: connection)

                try transactionBlock(transaction)
                if transaction.autocommit == true {
                    try transaction.commitBlock(transaction.succeed)
                    transaction.commitBlock = { _ in }
                }

            } else {
                print("Error beginning transaction: \(response)")
                let error = BoltClientError.queryUnsuccessful
                transaction.commitBlock = { _ in }
                throw error
            }
        }

        transactionGroup.wait()
    }
    
    /*
    - parameter connection: The connection to perform the pullAll on - must be the same that the originating query was on
     */
    internal func pullSynchronouslyAndIgnore(connection: Connection) {
        let dispatchGroup = DispatchGroup()
        let pullRequest = BoltRequest.pullAll()
        dispatchGroup.enter()
        do {
            try connection.request(pullRequest) { (success, response) in

                if let bookmark = self.getBookmark(connection: connection) {
                    currentTransaction?.bookmark = bookmark
                }
                dispatchGroup.leave()
            }
        } catch let error {
            print("Unhandled error while pulling to ignore all response data: \(error.localizedDescription)")
            dispatchGroup.leave()
        }
        dispatchGroup.wait()

    }

    /**
     Pull all data, for use after executing a query that puts the Neo4j bolt server in streaming mode

     Requires an established connection

     Asynchronous, so the function returns straight away. It is not defined what thread the completionblock will run on,
     so if you need it to run on main thread or another thread, make sure to dispatch to this that thread

     - parameter connection: The connection to perform the pullAll on - must be the same that the originating query was on
     - parameter partialQueryResult: If, for instance when executing the Cypher query, a partial QueryResult was given, pass it in here to have it fully populated in the completion result block
     - parameter completionBlock: Completion result-block that provides either a fully update QueryResult if a QueryResult was given, or a partial QueryResult if no prior QueryResult as given. If a failure has occurred, the Result contains an Error to explain what went wrong
     */
    public func pullAll(connection: Connection, partialQueryResult: QueryResult = QueryResult(), completionBlock: ((Result<(Bool, QueryResult), AnyError>) -> ())? = nil) {
        let pullRequest = BoltRequest.pullAll()
        do {
            try connection.request(pullRequest) { (successResponse, responses) in

                let result = parseResponses(responses: responses, result: partialQueryResult)
                completionBlock?(.success((successResponse, result)))
            }
        } catch let error as Socket.Error {
            completionBlock?(.failure(AnyError(error)))
        } catch let error {
            completionBlock?(.failure(AnyError(error)))
            print("Unexpected error while pulling all response data: \(error.localizedDescription)")
        }

    }

    /// Get the current transaction bookmark
    public func getBookmark(connection: Connection) -> String? {
        return connection.currentTransactionBookmark
    }

}

extension BoltClient { // Node functions

    //MARK: Create

    public func createAndReturnNode(node: Node, completionBlock: ((Result<Node, AnyError>) -> ())?) {
        let request = node.createRequest()
        performRequestWithReturnNode(request: request, completionBlock: completionBlock)
    }

    public func createAndReturnNodeSync(node: Node) -> Result<Node, AnyError> {

        let group = DispatchGroup()
        group.enter()

        var theResult: Result<Node, AnyError> = .failure(AnyError(BoltClientError.unknownError))
        createAndReturnNode(node: node) { result in
            theResult = result
            group.leave()
        }

        group.wait()
        return theResult
    }

    public func createNode(node: Node, connection: Connection, completionBlock: ((Result<Bool, AnyError>) -> ())?) {
        let request = node.createRequest(withReturnStatement: false)
        performRequestWithNoReturnNode(connection: connection, request: request, completionBlock: completionBlock)
    }

    public func createNodeSync(node: Node) -> Result<Bool, AnyError> {

        let connection = getConnection()
        let group = DispatchGroup()
        group.enter()

        var theResult: Result<Bool, AnyError> = .failure(AnyError(BoltClientError.unknownError))
        createNode(node: node, connection: connection) { result in
            theResult = result
            self.pullSynchronouslyAndIgnore(connection: connection)
            self.release(connection)
            group.leave()
        }

        group.wait()
        return theResult
    }

    public func createAndReturnNodes(nodes: [Node], completionBlock: ((Result<[Node], AnyError>) -> ())?) {
        let connection = getConnection()
        let request = nodes.createRequest()
        execute(connection: connection, request: request) { response in
            switch response {
            case let .failure(error):
                self.release(connection)
                completionBlock?(.failure(error))
            case let .success((isSuccess, partialQueryResult)):
                if !isSuccess {
                    let error = AnyError(BoltClientError.queryUnsuccessful)
                    self.release(connection)
                    completionBlock?(.failure(error))
                } else {
                    self.pullAll(connection: connection, partialQueryResult: partialQueryResult) { response in
                        self.release(connection)
                        switch response {
                        case let .failure(error):
                            completionBlock?(.failure(error))
                        case let .success((isSuccess, queryResult)):
                            if !isSuccess {
                                let error = AnyError(BoltClientError.fetchingRecordsUnsuccessful)
                                completionBlock?(.failure(error))
                            } else {
                                let nodes: [Node] = queryResult.nodes.map { $0.value }
                                completionBlock?(.success(nodes))
                            }
                        }
                    }
                }
            }
        }
    }

    public func createAndReturnNodesSync(nodes: [Node]) -> Result<[Node], AnyError> {

        let group = DispatchGroup()
        group.enter()

        var theResult: Result<[Node], AnyError> = .failure(AnyError(BoltClientError.unknownError))
        createAndReturnNodes(nodes: nodes) { result in
            theResult = result
            group.leave()
        }

        group.wait()
        return theResult
    }

    public func createNodes(nodes: [Node], connection: Connection, completionBlock: ((Result<Bool, AnyError>) -> ())?) {
        let request = nodes.createRequest(withReturnStatement: false)
        execute(connection: connection, request: request) { response in
            switch response {
            case let .failure(error):
                completionBlock?(.failure(error))
            case let .success((isSuccess, _)):
                completionBlock?(.success(isSuccess))
            }
        }
    }

    public func createNodesSync(nodes: [Node]) -> Result<Bool, AnyError> {

        let connection = getConnection()
        let group = DispatchGroup()
        group.enter()

        var theResult: Result<Bool, AnyError> = .failure(AnyError(BoltClientError.unknownError))
        createNodes(nodes: nodes, connection: connection) { result in
            theResult = result
            self.pullSynchronouslyAndIgnore(connection: connection) // ignore result
            self.release(connection)
            group.leave()
        }

        group.wait()
        return theResult
    }

    //MARK: Update
    public func updateAndReturnNode(node: Node, completionBlock: ((Result<Node, AnyError>) -> ())?) {

        let request = node.updateRequest()
        performRequestWithReturnNode(request: request, completionBlock: completionBlock)
    }

    private func performRequestWithReturnNode(request: Request, completionBlock: ((Result<Node, AnyError>) -> ())?) {
        let connection = getConnection()
        execute(connection: connection, request: request) { response in
            switch response {
            case let .failure(error):
                self.release(connection)
                completionBlock?(.failure(error))
            case let .success((isSuccess, partialQueryResult)):
                if !isSuccess {
                    self.release(connection)
                    let error = AnyError(BoltClientError.queryUnsuccessful)
                    completionBlock?(.failure(error))
                } else {
                    self.pullAll(connection: connection, partialQueryResult: partialQueryResult) { response in
                        self.release(connection)
                        switch response {
                        case let .failure(error):
                            completionBlock?(.failure(error))
                        case let .success((isSuccess, queryResult)):
                            if !isSuccess {
                                let error = AnyError(BoltClientError.fetchingRecordsUnsuccessful)
                                completionBlock?(.failure(error))
                            } else {
                                if let (_, node) = queryResult.nodes.first {
                                    completionBlock?(.success(node))
                                } else {
                                    let error = AnyError(BoltClientError.missingNodeResponse)
                                    completionBlock?(.failure(error))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    public func updateAndReturnNodeSync(node: Node) -> Result<Node, AnyError> {

        let group = DispatchGroup()
        group.enter()

        var theResult: Result<Node, AnyError> = .failure(AnyError(BoltClientError.unknownError))
        updateAndReturnNode(node: node) { result in
            theResult = result
            group.leave()
        }

        group.wait()
        return theResult
    }

    public func updateNode(node: Node, connection: Connection, completionBlock: ((Result<Bool, AnyError>) -> ())?) {

        let request = node.updateRequest()
        performRequestWithNoReturnNode(connection: connection, request: request, completionBlock: completionBlock)
    }

    public func performRequestWithNoReturnNode(connection: Connection, request: Request, completionBlock: ((Result<Bool, AnyError>) -> ())?) {

        execute(connection: connection, request: request) { response in
            switch response {
            case let .failure(error):
                completionBlock?(.failure(error))
            case let .success((isSuccess, _)):
                completionBlock?(.success(isSuccess))
            }
        }
    }

    public func updateNodeSync(node: Node) -> Result<Bool, AnyError> {

        let connection = getConnection()
        let group = DispatchGroup()
        group.enter()

        var theResult: Result<Bool, AnyError> = .failure(AnyError(BoltClientError.unknownError))
        updateNode(node: node, connection: connection) { result in
            theResult = result
            group.leave()
        }

        group.wait()
        self.pullSynchronouslyAndIgnore(connection: connection)
        self.release(connection)
        return theResult
    }

    public func updateAndReturnNodes(nodes: [Node], connection: Connection, completionBlock: ((Result<[Node], AnyError>) -> ())?) {
        let request = nodes.updateRequest()
        execute(connection: connection, request: request) { response in
            switch response {
            case let .failure(error):
                completionBlock?(.failure(error))
            case let .success((isSuccess, partialQueryResult)):
                if !isSuccess {
                    let error = AnyError(BoltClientError.queryUnsuccessful)
                    completionBlock?(.failure(error))
                } else {
                    self.pullAll(connection: connection, partialQueryResult: partialQueryResult) { response in
                        switch response {
                        case let .failure(error):
                            completionBlock?(.failure(error))
                        case let .success((isSuccess, queryResult)):
                            if !isSuccess {
                                let error = AnyError(BoltClientError.fetchingRecordsUnsuccessful)
                                completionBlock?(.failure(error))
                            } else {
                                let nodes: [Node] = queryResult.nodes.map { $0.value }
                                completionBlock?(.success(nodes))
                            }
                        }
                    }
                }
            }
        }
    }

    public func updateAndReturnNodesSync(nodes: [Node]) -> Result<[Node], AnyError> {

        let connection = getConnection()
        let group = DispatchGroup()
        group.enter()

        var theResult: Result<[Node], AnyError> = .failure(AnyError(BoltClientError.unknownError))
        updateAndReturnNodes(nodes: nodes, connection: connection) { result in
            theResult = result
            self.release(connection)
            group.leave()
        }

        group.wait()
        return theResult
    }

    public func updateNodes(nodes: [Node], connection: Connection, completionBlock: ((Result<Bool, AnyError>) -> ())?) {
        let request = nodes.updateRequest(withReturnStatement: false)
        execute(connection: connection, request: request) { response in
            switch response {
            case let .failure(error):
                completionBlock?(.failure(error))
            case let .success((isSuccess, _)):
                completionBlock?(.success(isSuccess))
            }
        }
    }

    public func updateNodesSync(nodes: [Node]) -> Result<Bool, AnyError> {

        let connection = getConnection()
        let group = DispatchGroup()
        group.enter()

        var theResult: Result<Bool, AnyError> = .failure(AnyError(BoltClientError.unknownError))
        updateNodes(nodes: nodes, connection: connection) { result in
            theResult = result
            self.release(connection)
            group.leave()
        }

        group.wait()
        return theResult
    }

    //MARK: Delete
    public func deleteNode(node: Node, connection: Connection, completionBlock: ((Result<Bool, AnyError>) -> ())?) {
        let request = node.deleteRequest()
        
        performRequestWithNoReturnNode(connection: connection, request: request, completionBlock: completionBlock)
    }

    public func deleteNodeSync(node: Node) -> Result<Bool, AnyError> {

        let connection = getConnection()
        let group = DispatchGroup()
        group.enter()

        var theResult: Result<Bool, AnyError> = .failure(AnyError(BoltClientError.unknownError))
        deleteNode(node: node, connection: connection) { result in
            theResult = result
            self.release(connection)
            group.leave()
        }

        group.wait()
        return theResult

    }

    public func deleteNodes(nodes: [Node], connection: Connection, completionBlock: ((Result<Bool, AnyError>) -> ())?) {
        let request = nodes.deleteRequest()
        performRequestWithNoReturnNode(connection: connection, request: request, completionBlock: completionBlock)
    }

    public func deleteNodesSync(nodes: [Node]) -> Result<Bool, AnyError> {

        let connection = getConnection()
        let group = DispatchGroup()
        group.enter()

        var theResult: Result<Bool, AnyError> = .failure(AnyError(BoltClientError.unknownError))
        deleteNodes(nodes: nodes, connection: connection) { result in
            theResult = result
            self.pullSynchronouslyAndIgnore(connection: connection) // ignore result
            self.release(connection)
            group.leave()
        }

        group.wait()
        return theResult
    }

    public func nodeBy(id: UInt64, completionBlock: ((Result<Node?, AnyError>) -> ())?) {
        let query = "MATCH (n) WHERE id(n) = {id} RETURN n"
        let params = ["id": Int64(id)]

        let connection = getConnection()
        // Perform query
        executeCypher(query, params: params, connection: connection) { result in
            switch result {
            case let .failure(error):
                print("Error: \(error)")
                self.release(connection)
                completionBlock?(.failure(error))
            case let .success((isSuccess, _partialResult)):
                if isSuccess == false {
                    self.release(connection)
                    let error = AnyError(BoltClientError.queryUnsuccessful)
                    completionBlock?(.failure(error))
                } else {

                    self.pullAll(connection: connection, partialQueryResult: _partialResult) { result in
                        self.release(connection)
                        switch result {
                        case let .failure(error):
                            completionBlock?(.failure(error))
                        case let .success(isSuccess, parsedResponses):
                            if isSuccess == false {
                                let error = AnyError(BoltClientError.queryUnsuccessful)
                                completionBlock?(.failure(error))
                            } else {
                                let nodes = parsedResponses.nodes.values
                                if nodes.count > 1 {
                                    let error = AnyError(BoltClientError.unexpectedNumberOfResponses)
                                    completionBlock?(.failure(error))
                                } else {
                                    completionBlock?(.success(nodes.first))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func queryResultToNodesResult(result: ((Result<(Bool, QueryResult), AnyError>))) -> (Result<[Node], AnyError>) {
        if let error = result.error {
            return .failure(error)
        }
        if let (isSuccess, queryResult) = result.value {
            if isSuccess == false {
                let error = AnyError(BoltClientError.queryUnsuccessful)
                return .failure(error)
            } else {
                let nodes: [Node] = Array<Node>(queryResult.nodes.values)
                return .success(nodes)
            }
        } else {
            let error = AnyError(BoltClientError.queryUnsuccessful)
            return .failure(error)
        }
    }

    public func nodesWith(labels: [String] = [], andProperties properties: [String:PackProtocol] = [:], skip: UInt64 = 0, limit: UInt64 = 25, completionBlock: ((Result<[Node], AnyError>) -> ())?) {
        let request = Node.queryFor(labels: labels, andProperties: properties, skip: skip, limit: limit)
        executeWithResult(request: request) { result in
            let transformedResult = self.queryResultToNodesResult(result: result)
            completionBlock?(transformedResult)
        }
    }

    public func nodesWith(properties: [String:PackProtocol] = [:], skip: UInt64 = 0, limit: UInt64 = 25, completionBlock: ((Result<[Node], AnyError>) -> ())?) {
        let request = Node.queryFor(labels: [], andProperties: properties, skip: skip, limit: limit)
        executeWithResult(request: request) { result in
            let transformedResult = self.queryResultToNodesResult(result: result)
            completionBlock?(transformedResult)
        }
    }

    public func nodesWith(label: String, andProperties properties: [String:PackProtocol] = [:], skip: UInt64 = 0, limit: UInt64 = 25, completionBlock: ((Result<[Node], AnyError>) -> ())?) {
        let request = Node.queryFor(labels: [label], andProperties: properties, skip: skip, limit: limit)
        executeWithResult(request: request) { result in
            let transformedResult = self.queryResultToNodesResult(result: result)
            completionBlock?(transformedResult)
        }
    }

}

extension BoltClient { // Relationship functions

    // Create

    public func relate(node: Node, to: Node, type: String, properties: [String:PackProtocol] = [:], connection: Connection, completionBlock: ((Result<Relationship, AnyError>) -> ())?) {
        let relationship = Relationship(fromNode: node, toNode: to, type: type, direction: .from, properties: properties)
        let request = relationship.createRequest()
        performRequestWithReturnRelationship(connection: connection, request: request, completionBlock: completionBlock)
    }

    public func relateSync(node: Node, to: Node, type: String, properties: [String:PackProtocol] = [:]) -> Result<Relationship, AnyError> {
        let connection = getConnection()
        let group = DispatchGroup()
        group.enter()

        var theResult: Result<Relationship, AnyError> = .failure(AnyError(BoltClientError.unknownError))
        relate(node: node, to: to, type: type, properties: properties, connection: connection) { result in
            theResult = result
            self.release(connection)
            group.leave()
        }

        group.wait()
        return theResult
    }

    public func createAndReturnRelationshipsSync(relationships: [Relationship]) -> Result<[Relationship], AnyError> {
        let request = relationships.createRequest(withReturnStatement: true)
        let group = DispatchGroup()
        group.enter()
        var theResult: Result<[Relationship], AnyError> = .failure(AnyError(BoltClientError.unknownError))
        executeWithResult(request: request) { result in
            switch result {
            case let .failure(error):
                theResult = .failure(AnyError(error))
            case let .success((isSuccess, queryResult)):
                if isSuccess == false {
                    let error = BoltClientError.queryUnsuccessful
                    theResult = .failure(AnyError(error))
                } else {
                    let relationships: [Relationship] = Array<Relationship>(queryResult.relationships.values)
                    theResult = .success(relationships)
                }
            }
            group.leave()
        }
        group.wait()

        return theResult
    }

    public func createAndReturnRelationships(relationships: [Relationship], completionBlock: ((Result<[Relationship], AnyError>) -> ())?) {
        let request = relationships.createRequest(withReturnStatement: true)
        executeWithResult(request: request) { result in
            switch result {
            case let .failure(error):
                completionBlock?(.failure(AnyError(error)))
            case let .success((isSuccess, queryResult)):
                if isSuccess == false {
                    let error = BoltClientError.queryUnsuccessful
                    completionBlock?(.failure(AnyError(error)))
                } else {
                    let relationships: [Relationship] = Array<Relationship>(queryResult.relationships.values)
                    completionBlock?(.success(relationships))
                }
            }
        }
    }

    public func createAndReturnRelationshipSync(relationship: Relationship) -> Result<Relationship, AnyError> {
        let request = relationship.createRequest(withReturnStatement: true)
        let group = DispatchGroup()
        group.enter()
        var theResult: Result<Relationship, AnyError> = .failure(AnyError(BoltClientError.unknownError))
        executeWithResult(request: request) { result in
            switch result {
            case let .failure(error):
                theResult = .failure(AnyError(error))
            case let .success((isSuccess, queryResult)):
                if isSuccess == false {
                    let error = BoltClientError.queryUnsuccessful
                    theResult = .failure(AnyError(error))
                } else {
                    if queryResult.relationships.count == 0 {
                        let error = BoltClientError.unknownError
                        theResult = .failure(AnyError(error))
                    } else if queryResult.relationships.count > 1 {
                        print("createAndReturnRelationshipSync() unexpectantly returned more than one relationship, returning first")
                        let relationship = queryResult.relationships.values.first!
                        theResult = .success(relationship)
                    } else {
                        let relationship = queryResult.relationships.values.first!
                        theResult = .success(relationship)
                    }
                }
            }
            group.leave()
        }
        group.wait()

        return theResult
    }

    public func createAndReturnRelationship(relationship: Relationship, completionBlock: ((Result<Relationship, AnyError>) -> ())?) {
        let request = relationship.createRequest(withReturnStatement: true)
        executeWithResult(request: request) { result in
            switch result {
            case let .failure(error):
                completionBlock?(.failure(AnyError(error)))
            case let .success((isSuccess, queryResult)):
                if isSuccess == false {
                    let error = BoltClientError.queryUnsuccessful
                    completionBlock?(.failure(AnyError(error)))
                } else {
                    if queryResult.relationships.count == 0 {
                        let error = BoltClientError.unknownError
                        completionBlock?(.failure(AnyError(error)))
                    } else if queryResult.relationships.count > 1 {
                        print("createAndReturnRelationshipSync() unexpectantly returned more than one relationship, returning first")
                        let relationship = queryResult.relationships.values.first!
                        completionBlock?(.success(relationship))
                    } else {
                        let relationship = queryResult.relationships.values.first!
                        completionBlock?(.success(relationship))
                    }
                }
            }
        }
    }


    //MARK: Update
    public func updateAndReturnRelationship(relationship: Relationship, connection: Connection, completionBlock: ((Result<Relationship, AnyError>) -> ())?) {

        let request = relationship.updateRequest()
        performRequestWithReturnRelationship(connection: connection, request: request, completionBlock: completionBlock)
    }

    private func performRequestWithReturnRelationship(connection: Connection, request: Request, completionBlock: ((Result<Relationship, AnyError>) -> ())?) {
        execute(connection: connection, request: request) { response in
            switch response {
            case let .failure(error):
                completionBlock?(.failure(error))
            case let .success((isSuccess, partialQueryResult)):
                if !isSuccess {
                    let error = AnyError(BoltClientError.queryUnsuccessful)
                    completionBlock?(.failure(error))
                } else {
                    self.pullAll(connection: connection, partialQueryResult: partialQueryResult) { response in
                        switch response {
                        case let .failure(error):
                            completionBlock?(.failure(error))
                        case let .success((isSuccess, queryResult)):
                            if !isSuccess {
                                let error = AnyError(BoltClientError.fetchingRecordsUnsuccessful)
                                completionBlock?(.failure(error))
                            } else {
                                if let (_, relationship) = queryResult.relationships.first {
                                    completionBlock?(.success(relationship))
                                } else {
                                    let error = AnyError(BoltClientError.missingRelationshipResponse)
                                    completionBlock?(.failure(error))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    public func updateAndReturnRelationshipSync(relationship: Relationship) -> Result<Relationship, AnyError> {

        let connection = getConnection()
        let group = DispatchGroup()
        group.enter()

        var theResult: Result<Relationship, AnyError> = .failure(AnyError(BoltClientError.unknownError))
        updateAndReturnRelationship(relationship: relationship, connection: connection) { result in
            theResult = result
            self.release(connection)
            group.leave()
        }

        group.wait()
        return theResult
    }

    public func updateRelationship(relationship: Relationship, connection: Connection, completionBlock: ((Result<Bool, AnyError>) -> ())?) {

        let request = relationship.updateRequest()
        performRequestWithNoReturnRelationship(connection: connection, request: request, completionBlock: completionBlock)
    }

    public func performRequestWithNoReturnRelationship(connection: Connection, request: Request, completionBlock: ((Result<Bool, AnyError>) -> ())?) {

        execute(connection: connection, request: request) { response in
            switch response {
            case let .failure(error):
                completionBlock?(.failure(error))
            case let .success((isSuccess, _)):
                completionBlock?(.success(isSuccess))
            }
        }
    }

    public func updateRelationshipSync(relationship: Relationship) -> Result<Bool, AnyError> {

        let connection = getConnection()
        let group = DispatchGroup()
        group.enter()

        var theResult: Result<Bool, AnyError> = .failure(AnyError(BoltClientError.unknownError))
        updateRelationship(relationship: relationship, connection: connection) { result in
            theResult = result
            self.release(connection)
            group.leave()
        }

        group.wait()
        return theResult
    }

    /*
    public func updateAndReturnRelationships(relationships: [Relationship], completionBlock: ((Result<[Relationship], AnyError>) -> ())?) {
        let request = relationships.updateRequest()
        execute(request: request) { response in
            switch response {
            case let .failure(error):
                completionBlock?(.failure(error))
            case let .success((isSuccess, partialQueryResult)):
                if !isSuccess {
                    let error = AnyError(BoltClientError.queryUnsuccessful)
                    completionBlock?(.failure(error))
                } else {
                    self.pullAll(partialQueryResult: partialQueryResult) { response in
                        switch response {
                        case let .failure(error):
                            completionBlock?(.failure(error))
                        case let .success((isSuccess, queryResult)):
                            if !isSuccess {
                                let error = AnyError(BoltClientError.fetchingRecordsUnsuccessful)
                                completionBlock?(.failure(error))
                            } else {
                                let relationships: [Relationship] = queryResult.relationships.map { $0.value }
                                completionBlock?(.success(relationships))
                            }
                        }
                    }
                }
            }
        }
    }

    public func updateAndReturnRelationshipsSync(relationships: [Relationship]) -> Result<[Relationship], AnyError> {

        let group = DispatchGroup()
        group.enter()

        var theResult: Result<[Relationship], AnyError> = .failure(AnyError(BoltClientError.unknownError))
        updateAndReturnRelationships(relationships: relationships) { result in
            theResult = result
            group.leave()
        }

        group.wait()
        return theResult
    }

    public func updateRelationships(relationships: [Relationship], completionBlock: ((Result<Bool, AnyError>) -> ())?) {
        let request = relationships.updateRequest(withReturnStatement: false)
        execute(request: request) { response in
            switch response {
            case let .failure(error):
                completionBlock?(.failure(error))
            case let .success((isSuccess, _)):
                completionBlock?(.success(isSuccess))
            }
        }
    }

    public func updateRelationshipsSync(relationships: [Relationship]) -> Result<Bool, AnyError> {

        let group = DispatchGroup()
        group.enter()

        var theResult: Result<Bool, AnyError> = .failure(AnyError(BoltClientError.unknownError))
        updateRelationships(relationships: relationships) { result in
            theResult = result
            group.leave()
        }

        group.wait()
        return theResult
    }*/

    //MARK: Delete
    public func deleteRelationship(relationship: Relationship, connection: Connection, completionBlock: ((Result<Bool, AnyError>) -> ())?) {
        let request = relationship.deleteRequest()
        performRequestWithNoReturnRelationship(connection: connection, request: request, completionBlock: completionBlock)
    }

    public func deleteRelationshipSync(relationship: Relationship) -> Result<Bool, AnyError> {

        let connection = getConnection()
        let group = DispatchGroup()
        group.enter()

        var theResult: Result<Bool, AnyError> = .failure(AnyError(BoltClientError.unknownError))
        deleteRelationship(relationship: relationship, connection: connection) { result in
            theResult = result
            self.release(connection)
            group.leave()
        }

        group.wait()
        return theResult

    }

    /*
    public func deleteRelationships(relationships: [Relationship], completionBlock: ((Result<[Bool], AnyError>) -> ())?) {
        let request = relationships.deleteRequest()
        performRequestWithNoReturnRelationship(request: request, completionBlock: completionBlock)
    }

    public func deleteRelationshipsSync(relationships: [Relationship]) -> Result<[Bool], AnyError> {

        let group = DispatchGroup()
        group.enter()

        var theResult: Result<Bool, AnyError> = .failure(AnyError(BoltClientError.unknownError))
        deleteRelationships(relationships: relationships) { result in
            theResult = result
            group.leave()
        }

        group.wait()
        return theResult
    }*/

    private func queryResultToRelationshipResult(result: ((Result<(Bool, QueryResult), AnyError>))) -> (Result<[Relationship], AnyError>) {
        if let error = result.error {
            return .failure(error)
        }
        if let (isSuccess, queryResult) = result.value {
            if isSuccess == false {
                let error = AnyError(BoltClientError.queryUnsuccessful)
                return .failure(error)
            } else {
                let nodes: [Relationship] = Array<Relationship>(queryResult.relationships.values)
                return .success(nodes)
            }
        } else {
            let error = AnyError(BoltClientError.queryUnsuccessful)
            return .failure(error)
        }
    }

    public func relationshipsWith(type: String, andProperties properties: [String:PackProtocol] = [:], skip: UInt64 = 0, limit: UInt64 = 25, completionBlock: ((Result<[Relationship], AnyError>) -> ())?) {
        let request = Relationship.queryFor(type: type, andProperties: properties, skip: skip, limit: limit)
        executeWithResult(request: request) { result in
            let transformedResult = self.queryResultToRelationshipResult(result: result)
            completionBlock?(transformedResult)
        }
    }

}
