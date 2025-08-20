"""
LLM Benchmark MCP Server implementation
"""

"""
    LLMBenchServer

An MCP server specifically for LLM benchmarking with setup and grade functions.
"""
function LLMBenchServer(;
    name::String="LLMBenchMCPServer",
    version::String="0.1.0",
    setup_fn::Union{Function, Nothing}=nothing,
    grade_fn::Union{Function, Nothing}=nothing,
    working_dir::String=pwd(),
    include_basic_tools::Bool=true
)
    # Create base MCP server
    server = ClaudeMCPTools.MCPServer(name=name, version=version)

    # Add basic tools if requested
    if include_basic_tools
        ClaudeMCPTools.register_tool!(server, "bash", ClaudeMCPTools.BashTool(working_dir=working_dir))
        ClaudeMCPTools.register_tool!(server, "str_replace_editor",
            ClaudeMCPTools.StrReplaceEditorTool(base_path=working_dir))
    end

    # Add setup_problem tool if function provided
    if setup_fn !== nothing
        ClaudeMCPTools.register_tool!(server, "setup_problem",
            SetupProblemTool(setup_fn, working_dir=working_dir))
    end

    # Add grade_problem tool if function provided
    if grade_fn !== nothing
        ClaudeMCPTools.register_tool!(server, "grade_problem",
            GradeProblemTool(grade_fn, working_dir=working_dir))
    end

    return server
end

# Main entry point for the LLMBenchMCPServer.
# Usage: julia --project -m LLMBenchMCPServer ModuleName [--workdir /path]
function @main(args)
    # Handle both array and varargs inputs
    if isa(args, Tuple)
        args = collect(args)
    end
    if isempty(args) || (length(args) == 1 && args[1] in ["--help", "-h"])
        println("""
        LLMBenchMCPServer - MCP server for LLM benchmarking

        Usage:
            julia --project -m LLMBenchMCPServer ModuleName [options]

        Arguments:
            ModuleName          Name of the module containing setup_problem and grade functions

        Options:
            --workdir PATH      Working directory (default: current directory)
            --no-basic-tools    Disable basic tools (bash, str_replace_editor)
            --verbose           Enable verbose output
            --help, -h          Show this help message

        The specified module should export:
            - setup_problem(workdir::String) -> String/Dict
                Returns the problem description

            - grade(workdir::String, transcript::String) -> Dict/Number
                Returns grading result with subscores, weights, and total score

        Example:
            julia --project -m LLMBenchMCPServer MyBenchmark
        """)
        return 0
    end

    # Parse arguments
    module_name = args[1]
    working_dir = pwd()
    include_basic_tools = true
    verbose = false

    i = 2
    while i <= length(args)
        if args[i] == "--workdir" && i + 1 <= length(args)
            working_dir = args[i + 1]
            i += 2
        elseif args[i] == "--no-basic-tools"
            include_basic_tools = false
            i += 1
        elseif args[i] == "--verbose"
            verbose = true
            i += 1
        else
            println("Warning: Unknown option: $(args[i])")
            i += 1
        end
    end

    # Ensure working directory exists
    if !isdir(working_dir)
        mkpath(working_dir)
    end

    # Load the module
    try
        # Load the module using Base.require
        mod_symbol = Symbol(module_name)
        mod = Base.require(Main, mod_symbol)

        # Extract functions
        setup_fn = nothing
        grade_fn = nothing

        if isdefined(mod, :setup_problem)
            setup_fn = getfield(mod, :setup_problem)
            if verbose
                println("Found setup_problem function in $module_name")
            end
        else
            println("Warning: No setup_problem function found in $module_name")
        end

        if isdefined(mod, :grade)
            grade_fn = getfield(mod, :grade)
            if verbose
                println("Found grade function in $module_name")
            end
        else
            println("Warning: No grade function found in $module_name")
        end

        # Create and run the server
        server = LLMBenchServer(
            name="$module_name-MCP",
            version="1.0.0",
            setup_fn=setup_fn,
            grade_fn=grade_fn,
            working_dir=working_dir,
            include_basic_tools=include_basic_tools
        )

        if verbose
            println("Starting MCP server for $module_name")
            println("Working directory: $working_dir")
            println("Tools registered: $(keys(server.tools))")
        end

        # Run the server in stdio mode
        ClaudeMCPTools.run_stdio_server(server, verbose=verbose)

    catch e
        println(stderr, "Error: $e")
        return 1
    end

    return 0
end
