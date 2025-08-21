"""
LLM Benchmark MCP Server implementation
"""

# Load Revise once per process using OncePerProcess
const load_revise = Base.OncePerProcess{Union{Module,Nothing}}() do
    try
        # Use PkgId to load Revise
        revise_pkg = Base.PkgId(Base.UUID("295af30f-e4ad-537b-8983-00126c2a3abe"), "Revise")
        return Base.require(revise_pkg)
    catch e
        @warn "Failed to load Revise package" exception=e
        return nothing
    end
end

"""
Run the Unix socket server with optional Revise support.
"""
function run_server_with_revise(server::ClaudeMCPTools.MCPServer, socket_path::String; 
                                verbose::Bool=false, use_revise::Bool=false)
    # Clean up existing socket if it exists
    if isfile(socket_path)
        rm(socket_path)
    end
    
    # Create the Unix socket
    socket = Sockets.listen(socket_path)
    
    if verbose
        @info "MCP server listening on Unix socket: $socket_path"
    end
    
    try
        while true
            # Accept connection
            client = Sockets.accept(socket)
            
            # Handle client in async task
            @async try
                while isopen(client)
                    # Read a line (JSON-RPC message)
                    line = readline(client)
                    if isempty(line)
                        break
                    end
                    
                    # Call Revise before processing if requested
                    if use_revise
                        revise_mod = load_revise()
                        if revise_mod !== nothing
                            try
                                # Use invokelatest to handle world age issues
                                Base.invokelatest(revise_mod.revise)
                                if verbose
                                    @debug "Revise.revise() called before processing request"
                                end
                            catch e
                                if verbose
                                    @warn "Revise.revise() failed" exception=e
                                end
                            end
                        end
                    end
                    
                    # Parse and handle the request
                    request = nothing
                    try
                        request = JSON.parse(line)
                        
                        # Use invokelatest for the handler to ensure we use refreshed code
                        response = if use_revise
                            Base.invokelatest(ClaudeMCPTools.handle_request, server, request)
                        else
                            ClaudeMCPTools.handle_request(server, request)
                        end
                        
                        # Send response
                        println(client, JSON.json(response))
                        flush(client)
                    catch e
                        # Send error response
                        error_response = Dict(
                            "jsonrpc" => "2.0",
                            "error" => Dict(
                                "code" => -32603,
                                "message" => "Internal error: $(string(e))"
                            ),
                            "id" => request !== nothing ? get(request, "id", nothing) : nothing
                        )
                        println(client, JSON.json(error_response))
                        flush(client)
                    end
                end
            catch e
                if verbose
                    @error "Client connection error" exception=(e, catch_backtrace())
                end
            finally
                close(client)
            end
        end
    finally
        close(socket)
    end
end

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
            --socket            Run server on Unix domain socket (creates socket in /tmp)
            --bind-socket PATH  Run server on Unix domain socket at specified path
            --revise            Load Revise.jl and auto-reload code changes
            --no-basic-tools    Disable basic tools (bash, str_replace_editor)
            --verbose           Enable verbose output
            --help, -h          Show this help message

        The specified module should export:
            - setup_problem(workdir::String) -> String/Dict
                Returns the problem description

            - grade(workdir::String, transcript::String) -> Dict/Number
                Returns grading result with subscores, weights, and total score

        Examples:
            julia --project -m LLMBenchMCPServer MyBenchmark
            julia --project -m LLMBenchMCPServer MyBenchmark --socket
        """)
        return 0
    end

    # Parse arguments
    module_name = args[1]
    working_dir = pwd()
    use_socket = false
    socket_path = ""  # For --bind-socket
    use_revise = false
    include_basic_tools = true
    verbose = false

    i = 2
    while i <= length(args)
        if args[i] == "--workdir" && i + 1 <= length(args)
            working_dir = args[i + 1]
            i += 2
        elseif args[i] == "--socket"
            use_socket = true
            i += 1
        elseif args[i] == "--bind-socket" && i + 1 <= length(args)
            use_socket = true
            socket_path = args[i + 1]
            i += 2
        elseif args[i] == "--revise"
            use_revise = true
            i += 1
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

    # Load Revise if requested
    if use_revise
        try
            # Load Revise dynamically
            Base.require(Main, :Revise)
            if verbose
                println("Revise.jl loaded for auto-reloading")
            end
        catch e
            println(stderr, "Warning: Could not load Revise.jl: $e")
            println(stderr, "Install with: using Pkg; Pkg.add(\"Revise\")")
            use_revise = false
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

        # Run the server in appropriate mode
        if use_socket
            # Use provided socket path or generate a unique one
            if isempty(socket_path)
                # Generate a unique socket path in /tmp
                timestamp = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
                pid = getpid()
                socket_path = "/tmp/mcp_$(module_name)_$(timestamp)_$(pid).sock"
            end
            
            println("Socket path: $socket_path")
            
            # Run server with or without Revise
            try
                if use_revise
                    # Use our custom server that calls Revise before each request
                    run_server_with_revise(server, socket_path, verbose=verbose, use_revise=true)
                else
                    # Use the standard ClaudeMCPTools server
                    ClaudeMCPTools.run_unix_socket_server(server, socket_path, verbose=verbose, cleanup=true)
                end
            finally
                # Ensure socket is cleaned up even on error
                if isfile(socket_path)
                    rm(socket_path)
                    if verbose
                        println("Cleaned up socket: $socket_path")
                    end
                end
            end
        else
            # For stdio mode, we can't easily intercept requests, so warn if Revise is requested
            if use_revise
                println(stderr, "Warning: --revise is not supported in stdio mode, only in socket mode")
            end
            ClaudeMCPTools.run_stdio_server(server, verbose=verbose)
        end

    catch e
        println(stderr, "Error: $e")
        return 1
    end

    return 0
end

# Export a regular main function for programmatic use
const main = @main
export main
