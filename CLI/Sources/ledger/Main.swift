import Foundation

@main
struct Main {
    static func main() async {
        let result = await Runner.run(Array(CommandLine.arguments.dropFirst()))
        if !result.out.isEmpty { FileHandle.standardOutput.write(Data(result.out.utf8)) }
        if !result.err.isEmpty { FileHandle.standardError.write(Data(result.err.utf8)) }
        exit(result.code)
    }
}
