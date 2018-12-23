import Foundation
import PackStream

public protocol ClientConfigurationProtocol {

    var hostname: String { get }
    var port: Int { get }
    var username: String { get }
    var password: String { get }
    var encrypted: Bool { get }
    var poolSize: ClosedRange<UInt> { get }
}

extension ClientConfigurationProtocol {

    public var hostname: String {
        return "localhost"
    }

    public var port: Int {
        return 7687
    }

    public var username: String {
        return "neo4j"
    }

    public var password: String {
        return "neo4j"
    }

    public var encrypted: Bool {
        return true
    }
    
    public var poolSize: ClosedRange<Int> {
        return 1...1
    }
}
