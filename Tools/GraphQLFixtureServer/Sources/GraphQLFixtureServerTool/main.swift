import Foundation
import GraphQLFixtureServer

exit(await GraphQLFixtureCommand.main(Array(CommandLine.arguments.dropFirst())))
