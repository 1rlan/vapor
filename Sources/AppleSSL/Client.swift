import Async
import Bits
import Security
import Foundation
import Dispatch
import TLS
import TCP

public final class AppleSSLClient: AppleSSLStream, SSLClient {
    public typealias Output = ByteBuffer
    
    var handshakeComplete = false
    
    var writeSource: DispatchSourceWrite
    
    var socket: TCPSocket
    
    var writeQueue: [Data]
    
    var readSource: DispatchSourceRead
    
    public var settings: SSLClientSettings
    
    public var peerDomainName: String?
    
    let connected = Promise<Void>()
    
    var descriptor: UnsafeMutablePointer<Int32>
    
    let context: SSLContext
    
    var queue: DispatchQueue
    
    /// A buffer storing all deciphered data received from the remote
    let outputBuffer = MutableByteBuffer(
        start: .allocate(capacity: Int(UInt16.max)),
        count: Int(UInt16.max)
    )
    
    var outputStream = BasicStream<ByteBuffer>()
    
    public func connect(hostname: String, port: UInt16) throws -> Future<Void> {
        if let peerDomainName = peerDomainName {
            try assert(status: SSLSetPeerDomainName(context, peerDomainName, peerDomainName.count))
        }
        
        try socket.connect(hostname: hostname, port: port)
        
        try self.initialize()
        
        return connected.future
    }
    
    public convenience init(settings: SSLClientSettings, on eventLoop: EventLoop) throws {
        let socket = try TCPSocket()
        
        try self.init(upgrading: socket, settings: settings, on: eventLoop)
    }
    
    public init(upgrading socket: TCPSocket, settings: SSLClientSettings, on eventLoop: EventLoop) throws {
        self.socket = socket
        self.settings = settings
        self.writeQueue = []
        
        guard let context = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw AppleSSLError(.cannotCreateContext)
        }
        
        self.context = context
        self.queue = eventLoop.queue
        
        self.readSource = DispatchSource.makeReadSource(
            fileDescriptor: socket.descriptor,
            queue: eventLoop.queue
        )
        
        self.writeSource = DispatchSource.makeWriteSource(fileDescriptor: socket.descriptor, queue: queue)
        
        self.descriptor = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        self.descriptor.pointee = self.socket.descriptor
        
        if let clientCertificate = settings.clientCertificate {
            try self.setCertificate(to: clientCertificate, for: context)
        }
        
        self.initializeDispatchSources()
        
        self.readSource.resume()
        self.writeSource.resume()
    }
    
    deinit {
        outputBuffer.baseAddress?.deallocate(capacity: outputBuffer.count)
        self.descriptor.deallocate(capacity: 1)
    }
}
