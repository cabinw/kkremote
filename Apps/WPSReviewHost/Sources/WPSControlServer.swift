import Foundation
import Network

final class WPSControlServer {
    private let listener: NWListener
    private let token: String
    private let handler: @MainActor (Data) async -> (Int,Data)
    init(port:UInt16,token:String,handler:@escaping @MainActor (Data) async -> (Int,Data)) throws {
        self.token=token;self.handler=handler
        let parameters=NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!)
        listener=try NWListener(using:parameters)
        listener.newConnectionHandler={ [weak self] connection in self?.accept(connection) }
        listener.start(queue:.main)
    }
    private func accept(_ connection:NWConnection) {
        connection.start(queue:.main)
        let deadline=DispatchWorkItem { connection.cancel() }
        DispatchQueue.main.asyncAfter(deadline:.now()+30,execute:deadline)
        read(connection,buffer:Data(),deadline:deadline)
    }
    private func read(_ connection:NWConnection,buffer:Data,deadline:DispatchWorkItem) {
        connection.receive(minimumIncompleteLength:1,maximumLength:16384) { [weak self] bytes,_,done,error in
            guard let self else { connection.cancel();return }
            var buffer=buffer;buffer.append(bytes ?? Data())
            guard buffer.count<=32768,error==nil else { deadline.cancel();connection.cancel();return }
            if let split=buffer.range(of:Data("\r\n\r\n".utf8)),
               let header=String(data:buffer[..<split.lowerBound],encoding:.utf8) {
                let lines=header.components(separatedBy:"\r\n")
                let fields=Dictionary(lines.dropFirst().compactMap { line -> (String,String)? in
                    guard let i=line.firstIndex(of:":") else { return nil }
                    return (line[..<i].lowercased(),line[line.index(after:i)...].trimmingCharacters(in:.whitespaces))
                },uniquingKeysWith:{_,new in new})
                guard lines.first=="POST /control HTTP/1.1",fields["authorization"]=="Bearer \(self.token)",
                      let length=Int(fields["content-length"] ?? ""),length>=0,length<=16384 else {
                    self.reply(connection,status:403,data:Data("{}".utf8));deadline.cancel();return
                }
                if buffer.count-split.upperBound>=length {
                    let body=Data(buffer[split.upperBound..<split.upperBound+length])
                    Task { @MainActor in
                        let result=await self.handler(body)
                        self.reply(connection,status:result.0,data:result.1);deadline.cancel()
                    }
                    return
                }
            }
            if done { deadline.cancel();connection.cancel() }
            else { self.read(connection,buffer:buffer,deadline:deadline) }
        }
    }
    private func reply(_ connection:NWConnection,status:Int,data:Data) {
        var response=Data("HTTP/1.1 \(status) \(status==200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(data)
        connection.send(content:response,completion:.contentProcessed { _ in connection.cancel() })
    }
}
