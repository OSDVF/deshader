//! ## Subset of Microsoft's Debug Adapter Protocol rewritten in Zig
//!
//! Event and Reponse structs are only the 'body' of the original DAP interfaces.
//! The `Source` interface (commonly seen as `source` field) is replaced by `path` string field.
//!
//! `InvalidatedEvent` is enriched with `context` and `numContexts` fields.
const std = @import("std");
const common = @import("../common.zig");

const String = []const u8;

pub const MessageType = enum {
    request,
    response,
    event,
};

pub const Message = struct {
    id: usize,
    format: String,
    variables: ?std.HashMap(String, String),
    showUser: ?bool,
    url: ?String,
    urlLabel: ?String,
};

pub const ErrorResponse = struct {
    seq: usize,
    type: MessageType,
    request_seq: usize,
    success: bool,
    command: String,
    message: ?String,
    body: Message,
};

pub const CancelRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    arguments: CancelArguments,
};

pub const CancelArguments = struct {
    requestId: ?usize,
    progressId: ?String,
};

pub const CancelResponse = struct {
    seq: usize,
    type: MessageType,
    request_seq: usize,
    success: bool,
};

pub const InitializedEvent = struct {
    seq: usize,
    type: MessageType,
    event: String,
    body: String,
};

pub const StoppedEvent = struct {
    reason: String, //'step' | 'breakpoint' | 'exception' | 'pause' | 'entry' | 'goto' | 'function breakpoint' | 'data breakpoint' | 'instruction breakpoint' |
    description: ?String,
    threadId: ?usize,
    preserveFocusHint: ?bool,
    text: ?String,
    allThreadsStopped: ?bool,
    hitBreakpointIds: ?[]const usize,
};

pub const ContinuedEvent = struct {
    threadId: usize,
    allThreadsContinued: bool,
};

pub const ExitedEvent = struct {
    exitCode: usize,
};

pub const TerminatedEvent = struct {
    seq: usize,
    type: MessageType,
    event: String,
    body: ?struct {
        restart: ?bool,
    },
};

pub const ThreadEvent = struct {
    /// 'started', 'exited'
    reason: String,
    threadId: usize,
};

pub const OutputEvent = struct {
    /// 'console', 'important', 'stdout', 'stderr', 'telemetry', ...
    category: ?String,
    output: String,
    /// 'start', 'startCollapsed', 'end', ...
    group: ?String,
    variablesReference: ?usize,
    path: String,
    line: ?usize,
    column: ?usize,
};

pub const Breakpoint = struct {
    /// For Deshader specifically, this is the stop point index.
    id: ?usize,
    verified: bool = false,
    message: ?String = null,
    line: ?usize = null,
    column: ?usize = null,
    endLine: ?usize = null,
    endColumn: ?usize = null,
    path: String,
    /// Reason for not being verified 'pending', 'failed'
    reason: ?String = null,
};

pub const Reason = enum { new, changed, removed };
pub const BreakpointEvent = struct {
    reason: Reason,
    breakpoint: Breakpoint,
};

pub const Module = struct {
    id: usize,
    name: String,
    path: String,
    isOptimized: ?bool,
    isUserCode: ?bool,
    version: ?String,
    dateTimeStamp: ?String,
};

pub const ModuleEvent = struct {
    reason: Reason,
    module: Module,
};

pub const LoadedSourceEvent = struct {
    reason: Reason,
    path: String,
};

pub const ProcessEvent = struct {
    name: String,
    systemProcessId: ?usize,
    isLocalProcess: ?bool,
    /// 'launch', 'attach', 'attachForSuspendedLaunch'
    startMethod: ?String,
    pointerSize: ?usize,
};

pub const ColumnDescriptor = struct {
    attributeName: String,
    label: String,
    format: ?String,
    /// 'String', 'usize', 'bool', 'unixTimestampUTC'
    type: ?String,
    width: ?usize,
};

pub const ChecksumAlgorithm = enum {
    MD5,
    SHA1,
    SHA256,
    SHA512,
};

pub const Capabilities = struct {
    supportsConfigurationDoneRequest: ?bool,
    supportsFunctionBreakpoints: ?bool,
    supportsConditionalBreakpoints: ?bool,
    supportsHitConditionalBreakpoints: ?bool,
    supportsEvaluateForHovers: ?bool,
    exceptionBreakpointFilters: ?[]const ExceptionBreakpointsFilter,
    supportsStepBack: ?bool,
    supportsSetVariable: ?bool,
    supportsRestartFrame: ?bool,
    supportsGotoTargetsRequest: ?bool,
    supportsStepInTargetsRequest: ?bool,
    supportsCompletionsRequest: ?bool,
    completionTriggerCharacters: ?[]const String,
    supportsModulesRequest: ?bool,
    additionalModuleColumns: ?[]const ColumnDescriptor,
    supportedChecksumAlgorithms: ?[]const ChecksumAlgorithm,
    supportsRestartRequest: ?bool,
    supportsExceptionOptions: ?bool,
    supportsValueFormattingOptions: ?bool,
    supportsExceptionInfoRequest: ?bool,
    supportTerminateDebuggee: ?bool,
    supportSuspendDebuggee: ?bool,
    supportsDelayedStackTraceLoading: ?bool,
    supportsLoadedSourcesRequest: ?bool,
    supportsLogPoints: ?bool,
    supportsTerminateThreadsRequest: ?bool,
    supportsSetExpression: ?bool,
    supportsTerminateRequest: ?bool,
    supportsDataBreakpoints: ?bool,
    supportsReadMemoryRequest: ?bool,
    supportsWriteMemoryRequest: ?bool,
    supportsDisassembleRequest: ?bool,
    supportsCancelRequest: ?bool,
    supportsBreakpointLocationsRequest: ?bool,
    supportsClipboardContext: ?bool,
    supportsSteppingGranularity: ?bool,
    supportsInstructionBreakpoints: ?bool,
    supportsExceptionFilterOptions: ?bool,
    supportsSingleThreadExecutionRequests: ?bool,
};

pub const CapabilitiesEvent = struct {
    capabilities: Capabilities,
};

pub const ProgressStartEvent = struct {
    progressId: String,
    title: String,
    requestId: ?usize,
    cancellable: ?bool,
    message: ?String,
    percentage: ?usize,
};

pub const ProgressUpdateEvent = struct {
    progressId: String,
    message: ?String,
    percentage: ?usize,
};

pub const ProgressEndEvent = struct {
    progressId: String,
    message: ?String,
};

pub const InvalidatedEvent = struct {
    pub const Areas = enum { all, stacks, threads, variables, contexts };
    areas: ?[]const Areas,
    /// If specified, the client only needs to refetch data related to this thread.
    threadId: ?usize = null,
    /// If specified, the client only needs to refetch data related to this stack frame (and the `threadId` is ignored).
    stackFrameId: ?usize = null,
    /// Deshader specific
    numContexts: ?usize = null,
};

pub const RunInTerminalRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    arguments: RunInTerminalRequestArguments,
};

pub const RunInTerminalRequestArguments = struct {
    /// 'integrated', 'external'
    kind: ?String,
    title: ?String,
    cwd: String,
    args: []const String,
    env: ?std.HashMap(String, String),
    argsCanBeInterpretedByShell: ?bool,
};

pub const RunInTerminalResponse = struct {
    processId: ?usize,
    shellProcessId: ?usize,
};

pub const StartDebuggingRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    arguments: StartDebuggingRequestArguments,
};

pub const StartDebuggingRequestArguments = struct {
    configuration: std.HashMap(String, String),
    /// 'launch', 'attach'
    request: String,
};

pub const StartDebuggingResponse = struct {
    seq: usize,
    type: MessageType,
    request_seq: usize,
    success: bool,
};

pub const InitializeRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    arguments: InitializeRequestArguments,
};

pub const InitializeRequestArguments = struct {
    clientID: ?String,
    clientName: ?String,
    adapterID: String,
    locale: ?String,
    linesStartAt1: ?bool,
    columnsStartAt1: ?bool,
    /// 'path' | 'uri' | String
    pathFormat: ?String,
    supportsVariableType: ?bool,
    supportsVariablePaging: ?bool,
    supportsRunInTerminalRequest: ?bool,
    supportsMemoryReferences: ?bool,
    supportsProgressReporting: ?bool,
    supportsInvalidatedEvent: ?bool,
    supportsMemoryEvent: ?bool,
    supportsArgsCanBeInterpretedByShell: ?bool,
    supportsStartDebuggingRequest: ?bool,
};

pub const InitializeResponse = struct {
    capabilities: Capabilities,
};

pub const ConfigurationDoneResponse = struct {
    seq: usize,
    type: MessageType,
    request_seq: usize,
    success: bool,
};

pub const LaunchRequest = struct {
    args: ?[]const String,
    console: ?ConsoleType,
    cwd: ?String,
    env: ?std.json.Value,
    program: String,
    noDebug: ?bool,
    showDebugOutput: ?bool,
    stopOnEntry: ?bool,
};

pub const ConsoleType = enum { debugConsole, integratedTerminal, externalTerminal };

pub const Protocol = enum { http, https, ws, wss };

pub const Connection = struct {
    host: String,
    port: u16,
    protocol: Protocol,
};

pub const AttachRequest = struct {
    connection: ?Connection,
    console: ?ConsoleType,
    showDebugOutput: ?bool,
    stopOnEntry: ?bool,
};

pub const AttachResponse = struct {
    seq: usize,
    type: MessageType,
    request_seq: usize,
    success: bool,
};

pub const RestartResponse = struct {
    seq: usize,
    type: MessageType,
    request_seq: usize,
    success: bool,
};

pub const DisconnectRequest = struct {
    restart: ?bool,
    terminateDebuggee: ?bool,
    suspendDebuggee: ?bool,
};

pub const DisconnectResponse = struct {
    seq: usize,
    type: MessageType,
    request_seq: usize,
    success: bool,
};

pub const TerminateRequest = struct {
    restart: ?bool,
};

pub const TerminateResponse = struct {
    seq: usize,
    type: MessageType,
    request_seq: usize,
    success: bool,
};

pub const BreakpointLocationArguments = struct {
    path: String,
    line: usize,
    column: ?usize,
    endLine: ?usize,
    endColumn: ?usize,
};

pub const BreakpointLocationsRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    arguments: ?BreakpointLocationArguments,
};

pub const BreakpointLocation = struct {
    line: usize,
    column: ?usize = null,
    endLine: ?usize = null,
    endColumn: ?usize = null,
};

/// Data payload passed to `SetBreakpoint` request
pub const SourceBreakpoint = struct {
    line: usize,
    column: ?usize = null,
    condition: ?String = null,
    hitCondition: ?String = null,
    logMessage: ?String = null,
};

pub const BreakpointLocationsResponse = struct {
    breakpoints: []const BreakpointLocation,
};

pub const SetBreakpointsRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    arguments: SetBreakpointsArguments,
};

pub const SetBreakpointsArguments = struct {
    path: String,
    breakpoints: ?[]const SourceBreakpoint,
    lines: ?[]usize,
    sourceModified: ?bool,
};

pub const SetBreakpointsResponse = struct {
    breakpoints: []Breakpoint,
};

pub const SetFunctionBreakpointsResponse = struct {
    breakpoints: []Breakpoint,
};

pub const SetExceptionBreakpointsRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    arguments: SetExceptionBreakpointsArguments,
};

pub const SetExceptionBreakpointsArguments = struct {
    filters: String,
    filterOptions: ?[]const ExceptionFilterOptions,
    exceptionOptions: ?[]const ExceptionOptions,
};

pub const SetExceptionBreakpointsResponse = struct {
    breakpoints: []Breakpoint,
};

pub const DataBreakpointInfoRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    arguments: DataBreakpointInfoArguments,
};

pub const DataBreakpointInfoArguments = struct {
    variablesReference: ?usize,
    name: String,
    frameId: ?usize,
};

pub const DataBreakpointInfoResponse = struct {
    dataId: ?String,
    description: String,
    /// 'read' | 'write' | 'readWrite'
    accessTypes: ?[]const DataBreakpoint.AccessType,
    /// Attribute indicates that a potential data breakpoint could be persisted across sessions.
    canPersist: ?bool,
};

pub const DataBreakpoint = struct {
    pub const AccessType = enum { read, write, readWrite };
    dataId: String,
    accessType: AccessType,
    condition: ?String,
    /// An expression that controls how many hits of the breakpoint are ignored.
    /// The debug adapter is expected to interpret the expression as needed.
    hitCondition: ?String,
};

pub const SetDataBreakpointsRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    arguments: SetDataBreakpointsArguments,
};

pub const SetDataBreakpointsArguments = struct {
    breakpoints: []const DataBreakpoint,
};

pub const SetDataBreakpointsResponse = struct {
    breakpoints: []const Breakpoint,
};

pub const SetInstructionBreakpointsResponse = struct {
    breakpoints: []const Breakpoint,
};

pub const ContinueRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    // command: 'continue',
    arguments: ContinueArguments,
};

pub const ContinueArguments = struct {
    threadId: usize,

    singleThread: ?bool,
};

pub const ContinueResponse = struct {
    allThreadsContinued: ?bool,
};

pub const NextRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    // command: 'next',
    arguments: NextArguments,
};

pub const NextArguments = struct {
    threadId: usize,

    singleThread: ?bool,

    granularity: ?SteppingGranularity,
};

pub const NextResponse = struct {
    seq: usize,
    type: MessageType,
    request_seq: usize,
    success: bool,
};

pub const StepInRequest = struct {
    seq: usize,
    type: MessageType,
    command: "stepIn",
    arguments: StepInArguments,
};

pub const StepInArguments = struct {
    threadId: usize,

    singleThread: ?bool,

    targetId: ?usize,

    granularity: ?SteppingGranularity,
};

pub const StepInResponse = struct {
    seq: usize,
    type: MessageType,
    request_seq: usize,
    success: bool,
};

pub const StepOutRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    // command: 'stepOut',
    arguments: StepOutArguments,
};

pub const StepOutArguments = struct {
    threadId: usize,

    singleThread: ?bool,

    granularity: ?SteppingGranularity,
};

pub const StepOutResponse = struct {
    seq: usize,
    type: MessageType,
    request_seq: usize,
    success: bool,
};

pub const StepBackRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    // command: 'stepBack',
    arguments: StepBackArguments,
};

pub const StepBackArguments = struct {
    threadId: usize,

    singleThread: ?bool,

    granularity: ?SteppingGranularity,
};

pub const StepBackResponse = struct {
    seq: usize,
    type: MessageType,
    request_seq: usize,
    success: bool,
};

pub const ReverseContinueRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    // command: 'reverseContinue',
    arguments: ReverseContinueArguments,
};

pub const ReverseContinueArguments = struct {
    threadId: usize,

    singleThread: ?bool,
};

pub const ReverseContinueResponse = struct {
    seq: usize,
    type: MessageType,
    request_seq: usize,
    success: bool,
};

pub const RestartFrameRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    // command: 'restartFrame',
    arguments: RestartFrameArguments,
};

pub const RestartFrameArguments = struct {
    frameId: usize,
};

pub const RestartFrameResponse = struct {
    seq: usize,
    type: MessageType,
    request_seq: usize,
    success: bool,
};

pub const GotoRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    // command: 'goto',
    arguments: GotoArguments,
};

pub const GotoArguments = struct {
    threadId: usize,

    targetId: usize,
};

pub const GotoResponse = struct {
    seq: usize,
    type: MessageType,
    request_seq: usize,
    success: bool,
};

pub const PauseRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    // command: 'pause',
    arguments: PauseArguments,
};

pub const PauseArguments = struct {
    threadId: usize,
};

pub const PauseResponse = struct {
    seq: usize,
    type: MessageType,
    request_seq: usize,
    success: bool,
};

pub const StackTraceRequest = struct {
    seq: usize,
    type: MessageType,
    command: "stackTrace",
    arguments: StackTraceArguments,
};

pub const StackTraceArguments = struct {
    threadId: usize,

    startFrame: ?usize,

    levels: ?usize,

    format: ?StackFrameFormat,
};

pub const StackTraceResponse = struct {
    stackFrames: []const StackFrame,

    totalFrames: ?usize,
};

pub const ScopesRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    // command: 'scopes',
    arguments: ScopesArguments,
};

pub const ScopesArguments = struct {
    frameId: usize,
};

pub const ScopesResponse = struct {
    scopes: []const Scope,
};

pub const VariablesRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    // command: 'variables',
    arguments: VariablesArguments,
};

pub const VariablesArguments = struct {
    variablesReference: usize,
    //'indexed' | 'named'
    filter: ?String,

    start: ?usize,

    count: ?usize,

    format: ?ValueFormat,
};

pub const VariablesResponse = struct {
    variables: []const Variable,
};

pub const SetVariableRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    // command: 'setVariable',
    arguments: SetVariableArguments,
};

pub const SetVariableArguments = struct {
    variablesReference: usize,

    name: String,

    value: String,

    format: ?ValueFormat,
};

pub const SetVariableResponse = struct {
    value: String,

    type: ?String,

    variablesReference: ?usize,

    namedVariables: ?usize,

    indexedVariables: ?usize,

    memoryReference: ?String,
};

/// The request retrieves the source code for a given source reference.
pub const SourceRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    // command: 'source',
    arguments: SourceArguments,
};

pub const SourceArguments = struct {
    path: String,
    /// 32 bit number: first 32 bits is the backend source ref, last 32 bits is the part index
    sourceReference: usize,
};

pub const SourceResponse = struct {
    content: String,

    mimeType: ?String,
};

pub const ThreadsRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    // command: 'threads',
};

pub const ThreadsResponse = struct {
    threads: []const Thread,
};

pub const TerminateThreadsRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    // command: 'terminateThreads',
    arguments: TerminateThreadsArguments,
};

pub const TerminateThreadsArguments = struct {
    threadIds: ?[]const usize,
};

pub const TerminateThreadsResponse = struct {
    seq: usize,
    type: MessageType,
    request_seq: usize,
    success: bool,
};

pub const ModulesRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    // command: 'modules',
    arguments: ModulesArguments,
};

pub const ModulesArguments = struct {
    startModule: ?usize,

    moduleCount: ?usize,
};

pub const ModulesResponse = struct {
    modules: []const Module,

    totalModules: ?usize,
};

pub const LoadedSourcesRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    // command: 'loadedSources',
    arguments: ?LoadedSourcesArguments,
};

pub const LoadedSourcesArguments = struct {};

pub const LoadedSourcesResponse = struct {
    paths: []const String,
};

pub const EvaluateRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    // command: 'evaluate',
    arguments: EvaluateArguments,
};

pub const EvaluateArguments = struct {
    expression: String,

    frameId: ?usize,
    /// 'watch' | 'repl' | 'hover' | 'clipboard' | 'variables' | String
    context: ?String,

    format: ?ValueFormat,
};

pub const EvaluateResponse = struct {
    result: String,
    /// The type of the evaluate result.
    /// This attribute should only be returned by a debug adapter if the corresponding capability `supportsVariableType` is true.
    type: ?String = null,
    /// Properties of an evaluate result that can be used to determine how to render the result in the UI.
    presentationHint: ?VariablePresentationHint = null,
    ///  If `variablesReference` is > 0, the evaluate result is structured and its children can be retrieved by passing `variablesReference` to the `variables` request as long as execution remains suspended. See 'Lifetime of Object References' in the Overview section for details.
    variablesReference: usize = 0,
    /// The number of named child variables.
    /// The client can use this information to present the variables in a paged UI and fetch them in chunks.
    /// The value should be less than or equal to 2147483647 (2^31-1).
    namedVariables: ?usize = null,
    /// The number of indexed child variables.
    /// The client can use this information to present the variables in a paged UI and fetch them in chunks.
    /// The value should be less than or equal to 2147483647 (2^31-1).
    indexedVariables: ?usize = null,
    /// A memory reference to a location appropriate for this result.
    /// For pointer type eval results, this is generally a reference to the memory address contained in the pointer.
    /// This attribute may be returned by a debug adapter if corresponding capability `supportsMemoryReferences` is true.
    memoryReference: ?String = null,
};

pub const SetExpressionRequest = struct {
    seq: usize,
    type: MessageType,
    command: String,
    // command: 'setExpression',
    arguments: SetExpressionArguments,
};

pub const SetExpressionArguments = struct {
    expression: String,

    value: String,

    frameId: ?usize,

    format: ?ValueFormat,
};

pub const SetExpressionResponse = struct {
    value: String,

    type: ?String,

    presentationHint: ?VariablePresentationHint,

    variablesReference: ?usize,

    namedVariables: ?usize,

    indexedVariables: ?usize,

    memoryReference: ?String,
};
pub const StepInTargetsRequest = struct {
    seq: usize,
    type: MessageType,
    // command: 'stepInTargets',
    arguments: StepInTargetsArguments,
};

///  Arguments for `stepInTargets` request.
pub const StepInTargetsArguments = struct {
    ///  The stack frame for which to retrieve the possible step-in targets.
    frameId: usize,
};

///  Response to `stepInTargets` request.
pub const StepInTargetsResponse = struct {
    ///  The possible step-in targets of the specified source location.
    targets: []const StepInTarget,
};

pub const GotoTargetsRequest = struct {
    seq: usize,
    type: MessageType,
    // command: 'gotoTargets',
    arguments: GotoTargetsArguments,
};

///  Arguments for `gotoTargets` request.
pub const GotoTargetsArguments = struct {
    ///  The source location for which the goto targets are determined.
    path: String,
    ///  The line location for which the goto targets are determined.
    line: usize,
    ///  The position within `line` for which the goto targets are determined. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    column: ?usize,
};

///  Response to `gotoTargets` request.
pub const GotoTargetsResponse = struct {
    ///  The possible goto targets of the specified location.
    targets: []const GotoTarget,
};

pub const CompletionsRequest = struct {
    seq: usize,
    type: MessageType,
    // command: 'completions',
    arguments: CompletionsArguments,
};

///  Arguments for `completions` request.
pub const CompletionsArguments = struct {
    ///  Returns completions in the scope of this stack frame. If not specified, the completions are returned for the global scope.
    frameId: ?usize,
    ///  One or more source lines. Typically this is the text users have typed into the debug console before they asked for completion.
    text: String,
    ///  The position within `text` for which to determine the completion proposals. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    column: usize,
    ///  A line for which to determine the completion proposals. If missing the first line of the text is assumed.
    line: ?usize,
};

///  Response to `completions` request.
pub const CompletionsResponse = struct {
    ///  The possible completions for .
    targets: []const CompletionItem,
};

pub const ExceptionInfoRequest = struct {
    seq: usize,
    type: MessageType,
    // command: 'exceptionInfo',
    arguments: ExceptionInfoArguments,
};

///  Arguments for `exceptionInfo` request.
pub const ExceptionInfoArguments = struct {
    ///  Thread for which exception information should be retrieved.
    threadId: usize,
};

///  Response to `exceptionInfo` request.
pub const ExceptionInfoResponse = struct {
    ///  ID of the exception that was thrown.
    exceptionId: String,
    ///  Descriptive text for the exception.
    description: ?String,
    ///  Mode that caused the exception notification to be raised.
    breakMode: ExceptionBreakMode,
    ///  Detailed information about the exception.
    details: ?ExceptionDetails,
};

pub const ReadMemoryRequest = struct {
    seq: usize,
    type: MessageType,
    // command: 'readMemory',
    arguments: ReadMemoryArguments,
};

///  Arguments for `readMemory` request.
pub const ReadMemoryArguments = struct {
    ///  Memory reference to the base location from which data should be read.
    memoryReference: String,
    ///  Offset (in bytes) to be applied to the reference location before reading data. Can be negative.
    offset: ?usize,
    ///  usize of bytes to read at the specified location and offset.
    count: usize,
};

///  Response to `readMemory` request.
pub const ReadMemoryResponse = struct {
    address: String,

    unreadableBytes: ?usize,
    ///  The bytes read from memory, encoded using base64. If the decoded length of `data` is less than the requested `count` in the original `readMemory` request, and `unreadableBytes` is zero or omitted, then the client should assume it's reached the end of readable memory.
    data: ?String,
};

pub const WriteMemoryRequest = struct {
    seq: usize,
    type: MessageType,
    // command: 'writeMemory',
    arguments: WriteMemoryArguments,
};

///  Arguments for `writeMemory` request.
pub const WriteMemoryArguments = struct {
    ///  Memory reference to the base location to which data should be written.
    memoryReference: String,
    ///  Offset (in bytes) to be applied to the reference location before writing data. Can be negative.
    offset: ?usize,

    allowPartial: ?bool,
    ///  Bytes to write, encoded using base64.
    data: String,
};

///  Response to `writeMemory` request.
pub const WriteMemoryResponse = struct {
    ///  Property that should be returned when `allowPartial` is true to indicate the offset of the first byte of data successfully written. Can be negative.
    offset: ?usize,
    ///  Property that should be returned when `allowPartial` is true to indicate the usize of bytes starting from address that were successfully written.
    bytesWritten: ?usize,
};

pub const ExceptionBreakpointsFilter = struct {
    ///  The internal ID of the filter option. This value is passed to the `setExceptionBreakpoints` request.
    filter: String,
    ///  The name of the filter option. This is shown in the UI.
    label: String,
    ///  A help text providing additional information about the exception filter. This String is typically shown as a hover and can be translated.
    description: ?String,
    ///  Initial value of the filter option. If not specified a value false is assumed.
    default: ?bool,
    ///  Controls whether a condition can be specified for this filter option. If false or missing, a condition can not be set.
    supportsCondition: ?bool,
    ///  A help text providing information about the condition. This String is shown as the placeholder text for a text box and can be translated.
    conditionDescription: ?String,
};
pub const Thread = struct {
    ///  Unique identifier for the thread.
    id: usize,
    ///  The name of the thread.
    name: String,
};
pub const StackFrame = struct {
    id: usize,
    ///  The name of the stack frame, typically a method name.
    name: String,
    ///  The source of the frame.
    path: String,
    ///  The line within the source of the frame. If the source attribute is missing or doesn't exist, `line` is 0 and should be ignored by the client.
    line: usize,
    ///  Start position of the range covered by the stack frame. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based. If attribute `source` is missing or doesn't exist, `column` is 0 and should be ignored by the client.
    column: usize,
    ///  The end line of the range covered by the stack frame.
    endLine: ?usize = null,
    ///  End position of the range covered by the stack frame. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    endColumn: ?usize = null,
    ///  Indicates whether this frame can be restarted with the `restart` request. Clients should only use this if the debug adapter supports the `restart` request and the corresponding capability `supportsRestartRequest` is true. If a debug adapter has this capability, then `canRestart` defaults to `true` if the property is absent.
    canRestart: ?bool = null,
    ///  A memory reference for the current instruction pointer in this frame.
    instructionPointerReference: ?String = null,
    ///  The module associated with this frame, if any.
    /// usize | String
    moduleId: ?String = null,
    /// 'normal' | 'label' | 'subtle'
    presentationHint: ?String = null,
};

///  A `Scope` is a named container for variables. Optionally a scope can map to a source or a range within a source.
pub const Scope = struct {
    ///  Name of the scope such as 'Arguments', 'Locals', or 'Registers'. This String is shown in the UI as is and can be translated.
    name: String,
    /// 'arguments' | 'locals' | 'registers' |...
    presentationHint: ?String,
    ///  The variables of this scope can be retrieved by passing the value of `variablesReference` to the `variables` request as long as execution remains suspended. See 'Lifetime of Object References' in the Overview section for details.
    variablesReference: usize,

    namedVariables: ?usize,

    indexedVariables: ?usize,
    ///  If true, the usize of variables in this scope is large or expensive to retrieve.
    expensive: bool,
    ///  The source for this scope.
    path: String,
    ///  The start line of the range covered by this scope.
    line: ?usize,
    ///  Start position of the range covered by the scope. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    column: ?usize,
    ///  The end line of the range covered by this scope.
    endLine: ?usize,
    ///  End position of the range covered by the scope. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    endColumn: ?usize,
};

pub const Variable = struct {
    ///  The variable's name.
    name: String,

    value: String,

    type: ?String,
    ///  Properties of a variable that can be used to determine how to render the variable in the UI.
    presentationHint: ?VariablePresentationHint,
    ///  The evaluatable name of this variable which can be passed to the `evaluate` request to fetch the variable's value.
    evaluateName: ?String,
    ///  If `variablesReference` is > 0, the variable is structured and its children can be retrieved by passing `variablesReference` to the `variables` request as long as execution remains suspended. See 'Lifetime of Object References' in the Overview section for details.
    variablesReference: usize,

    namedVariables: ?usize,

    indexedVariables: ?usize,

    memoryReference: ?String,
};
///  Properties of a variable that can be used to determine how to render the variable in the UI.
pub const VariablePresentationHint = struct {
    /// ?'property' | 'method' | 'class' | 'data' | 'event' | 'baseClass' | 'innerClass' | 'pub const' | 'mostDerivedClass' | 'virtual' | 'dataBreakpoint' | String,
    kind: String,
    /// 'static' | 'constant' | 'readOnly' | 'rawString' | 'hasObjectId' | 'canHaveObjectId' | 'hasSideEffects' | 'hasDataBreakpoint' | String
    attributes: ?String,
    /// ?'public' | 'private' | 'protected' | 'internal' | 'final' | String,
    visibility: ?String,

    lazy: ?bool,
};

///type SteppingGranularity = 'statement' | 'line' | 'instruction'
pub const SteppingGranularity = enum {
    statement,
    line,
    instruction,
};

///  A `StepInTarget` can be used in the `stepIn` request and determines into which single target the `stepIn` request should step.
pub const StepInTarget = struct {
    ///  Unique identifier for a step-in target.
    id: usize,
    ///  The name of the step-in target (shown in the UI).
    label: String,
    ///  The line of the step-in target.
    line: ?usize,
    ///  Start position of the range covered by the step in target. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    column: ?usize,
    ///  The end line of the range covered by the step-in target.
    endLine: ?usize,
    ///  End position of the range covered by the step in target. It is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based.
    endColumn: ?usize,
};

pub const GotoTarget = struct {
    ///  Unique identifier for a goto target. This is used in the `goto` request.
    id: usize,
    ///  The name of the goto target (shown in the UI).
    label: String,
    ///  The line of the goto target.
    line: usize,
    ///  The column of the goto target.
    column: ?usize,
    ///  The end line of the range covered by the goto target.
    endLine: ?usize,
    ///  The end column of the range covered by the goto target.
    endColumn: ?usize,
    ///  A memory reference for the instruction pointer value represented by this target.
    instructionPointerReference: ?String,
};

///  `CompletionItems` are the suggestions returned from the `completions` request.
pub const CompletionItem = struct {
    ///  The label of this completion item. By default this is also the text that is inserted when selecting this completion.
    label: String,
    ///  If text is returned and not an empty String, then it is inserted instead of the label.
    text: ?String,
    ///  A String that should be used when comparing this item with other items. If not returned or an empty String, the `label` is used instead.
    sortText: ?String,
    ///  A human-readable String with additional information about this item, like type or symbol information.
    detail: ?String,
    ///  The item's type. Typically the client uses this information to render the item in the UI with an icon.
    type: ?CompletionItemType,
    ///  Start position (within the `text` attribute of the `completions` request) where the completion text is added. The position is measured in UTF-16 code units and the client capability `columnsStartAt1` determines whether it is 0- or 1-based. If the start position is omitted the text is added at the location specified by the `column` attribute of the `completions` request.
    start: ?usize,
    ///  Length determines how many characters are overwritten by the completion text and it is measured in UTF-16 code units. If missing the value 0 is assumed which results in the completion text being inserted.
    length: ?usize,
    ///  Determines the start of the new selection after the text has been inserted (or replaced). `selectionStart` is measured in UTF-16 code units and must be in the range 0 and length of the completion text. If omitted the selection starts at the end of the completion text.
    selectionStart: ?usize,
    ///  Determines the length of the new selection after the text has been inserted (or replaced) and it is measured in UTF-16 code units. The selection can not extend beyond the bounds of the completion text. If omitted the length is assumed to be 0.
    selectionLength: ?usize,
};

///  Some predefined types for the CompletionItem. Please note that not all clients have specific icons for all of them.
//type CompletionItemType = 'method' | 'function' | 'constructor' | 'field' | 'variable' | 'class' | 'interface' | 'module' | 'property' | 'unit' | 'value' | 'enum' | 'keyword' | 'snippet' | 'text' | 'color' | 'file' | 'reference' | 'customcolor'
pub const CompletionItemType = enum {
    method,
    function,
    constructor,
    field,
    variable,
    class,
    interface,
    module,
    property,
    unit,
    value,
    @"enum",
    keyword,
    snippet,
    text,
    color,
    file,
    reference,
    customcolor,
};

///  Names of checksum algorithms that may be supported by a debug adapter.
//type ChecksumAlgorithm = 'MD5' | 'SHA1' | 'SHA256' | 'timestamp'

///  The checksum of an item calculated by the specified algorithm.
pub const Checksum = struct {
    ///  The algorithm used to calculate this checksum.
    algorithm: ChecksumAlgorithm,
    ///  Value of the checksum, encoded as a hexadecimal value.
    checksum: String,
};

///  Provides formatting information for a value.
pub const ValueFormat = struct {
    ///  Display the value in hex.
    hex: ?bool,
};

///  Provides formatting information for a stack frame.
pub const StackFrameFormat = struct {
    hex: ?bool,
    ///  Displays parameters for the stack frame.
    parameters: ?bool,
    ///  Displays the types of parameters for the stack frame.
    parameterTypes: ?bool,
    ///  Displays the names of parameters for the stack frame.
    parameterNames: ?bool,
    ///  Displays the values of parameters for the stack frame.
    parameterValues: ?bool,
    ///  Displays the line number of the stack frame.
    line: ?bool,
    ///  Displays the module of the stack frame.
    module: ?bool,
    ///  Includes all stack frames, including those the debug adapter might otherwise hide.
    includeAll: ?bool,
};

///  An `ExceptionFilterOptions` is used to specify an exception filter together with a condition for the `setExceptionBreakpoints` request.
pub const ExceptionFilterOptions = struct {
    ///  ID of an exception filter returned by the `exceptionBreakpointFilters` capability.
    filterId: String,

    condition: ?String,
};

///  An `ExceptionOptions` assigns configuration options to a set of exceptions.
pub const ExceptionOptions = struct {
    path: ?[]const ExceptionPathSegment,
    ///  Condition when a thrown exception should result in a break.
    breakMode: ExceptionBreakMode,
};

//type ExceptionBreakMode = 'never' | 'always' | 'unhandled' | 'userUnhandled'
pub const ExceptionBreakMode = enum {
    never,
    always,
    unhandled,
    userUnhandled,
};

pub const ExceptionPathSegment = struct {
    ///  If false or missing this segment matches the names provided, otherwise it matches anything except the names provided.
    negate: ?bool,
    ///  Depending on the value of `negate` the names that should match or not match.
    names: []const String,
};

///  Detailed information about an exception that has occurred.
pub const ExceptionDetails = struct {
    ///  Message contained in the exception.
    message: ?String,
    ///  Short type name of the exception object.
    typeName: ?String,
    ///  Fully-qualified type name of the exception object.
    fullTypeName: ?String,
    ///  An expression that can be evaluated in the current scope to obtain the exception object.
    evaluateName: ?String,
    ///  Stack trace at the time the exception was thrown.
    stackTrace: ?String,
    ///  Details of the exception contained by this exception, if any.
    innerException: ?[]const ExceptionDetails,
};
