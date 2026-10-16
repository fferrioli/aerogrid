public struct GridLayoutCmdArgs: CmdArgs {
    public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { commonState = .init(rawArgs) }
    public var operation: Lateinit<String> = .uninitialized
    public var data: String? = nil
    public static let parser: CmdParser<Self> = .init(
        kind: .gridLayout,
        help: "grid-layout [--workspace NAME] [--data JSON] (status|snapshot|restore|compact|wide|vertical|activate)",
        flags: ["--workspace": workspaceSubArgParser(), "--data": singleValueSubArgParser(\.data, "JSON", { .success($0) })],
        posArgs: [newMandatoryPosArgParser(\.operation, consumeStrCliArg, placeholder: "<operation>")]
    )
}
