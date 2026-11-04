import Foundation
import ReqlingKit

extension AppModel {
    /// The schema service the runner's gRPC runs resolve through, for the editor's Refresh (dropping cached
    /// reflection results) and for following `GRPCSchemaService.revision`.
    var grpcSchemas: GRPCSchemaService? {
        runner.grpcSchemas
    }
}
