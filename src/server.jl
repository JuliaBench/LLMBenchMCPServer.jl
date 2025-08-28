"""
LLM Benchmark MCP Server implementation
"""

# Load Revise once per process using OncePerProcess
if VERSION < v"1.12"
const load_revise = (args...,)->error("Only supported on 1.12")
else
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
                        
                        # Log incoming message to stderr in verbose mode
                        if verbose
                            println(stderr, "Incoming message: ", JSON.json(request, 2))
                            flush(stderr)
                        end
                        
                        # Use invokelatest for the handler to ensure we use refreshed code
                        response = if use_revise
                            Base.invokelatest(ClaudeMCPTools.handle_request, server, request)
                        else
                            ClaudeMCPTools.handle_request(server, request)
                        end
                        
                        # Log outgoing response to stderr in verbose mode
                        if verbose
                            println(stderr, "Outgoing response: ", JSON.json(response, 2))
                            flush(stderr)
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
    launch_in_sandbox(args::Vector{String})

Re-launch the LLMBenchMCPServer inside a Sandbox.jl sandbox.
"""
function launch_in_sandbox(args::Vector{String})::Cint
    # Check if Sandbox is available
    Sandbox = nothing
    try
        # Try to load Sandbox - it should be available if running within ClaudeBox
        Sandbox = Base.require(Base.PkgId(Base.UUID("a4e034a1-bbed-5493-bc6f-f0a4e1c5e439"), "Sandbox"))
    catch e
        # Sandbox not available, provide helpful error message
        println(stderr, """
        Error: Sandbox.jl is required for sandboxed execution but is not available.
        
        Options:
        1. Run with --direct flag to execute without sandboxing:
           julia --project -m LLMBenchMCPServer ModuleName --direct
           
        2. Run from within ClaudeBox environment where Sandbox.jl is available
        
        3. Install Sandbox.jl (requires BinaryBuilder2 ecosystem):
           ] add Sandbox
        """)
        return Cint(1)
    end
    
    # Get the host platform
    host_platform = Base.BinaryPlatforms.HostPlatform()
    
    # Create minimal mounts for the sandbox
    # We'll use a minimal Debian rootfs and mount the Julia installation
    mounts = Dict{String, Any}(
        "/" => Sandbox.MountInfo(Sandbox.debian_rootfs(; platform=host_platform), Sandbox.MountType.Overlayed),
        "/workspace" => Sandbox.MountInfo(pwd(), Sandbox.MountType.ReadWrite),
    )
    
    # Mount the Julia installation directory
    julia_bin = Base.julia_cmd().exec[1]
    julia_dir = dirname(dirname(julia_bin))  # Get Julia installation directory
    if isdir(julia_dir)
        mounts["/opt/julia"] = Sandbox.MountInfo(julia_dir, Sandbox.MountType.ReadOnly)
    end
    
    # Mount the current project directory (where LLMBenchMCPServer is)
    project_dir = dirname(dirname(@__FILE__))
    mounts["/opt/llmbench"] = Sandbox.MountInfo(project_dir, Sandbox.MountType.ReadOnly)
    
    # Set up environment variables
    env = Dict{String, String}(
        "PATH" => "/opt/julia/bin:/usr/local/bin:/usr/bin:/bin",
        "HOME" => "/root",
        "USER" => "root",
        "JULIA_PROJECT" => "/opt/llmbench",
    )
    
    # Build the command to run inside the sandbox
    # Add --direct flag to prevent infinite recursion
    new_args = copy(args)
    push!(new_args, "--direct")
    
    # Build the Julia command
    cmd = Cmd(["/opt/julia/bin/julia", "--project=/opt/llmbench", "-m", "LLMBenchMCPServer"])
    cmd = `$cmd $new_args`
    
    # Create the sandbox configuration
    config = Sandbox.SandboxConfig(
        mounts,
        env;
        stdin=Base.stdin,
        stdout=Base.stdout,
        stderr=Base.stderr,
        pwd="/workspace"
    )
    
    # Run in the sandbox
    exit_code = Cint(0)
    try
        Sandbox.with_executor() do exe
            # Run the command in the sandbox
            run(exe, config, cmd)
        end
    catch e
        println(stderr, "Error running in sandbox: $e")
        exit_code = Cint(1)
    end
    
    return exit_code
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
    include_basic_tools::Bool=true,
    bash_uid::Union{Int, Nothing}=nothing,
    bash_env::Dict{String,String}=Dict{String,String}()
)
    # Create base MCP server
    server = ClaudeMCPTools.MCPServer(name=name, version=version)

    # Add basic tools if requested
    if include_basic_tools
        ClaudeMCPTools.register_tool!(server, "bash", ClaudeMCPTools.BashTool(
            working_dir=working_dir,
            uid=bash_uid,
            env=bash_env
        ))
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
function (@main)(args)
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
            --direct            Run directly without sandboxing (default: run in sandbox)
            --bash-uid UID      Set UID for bash session execution (e.g., 1000)
            --bash-env KEY=VAL  Set environment variables for bash (can be used multiple times)
            --help, -h          Show this help message

        The specified module should export:
            - setup_problem(workdir::String) -> String/Dict
                Returns the problem description

            - grade(workdir::String, transcript::String) -> Dict/Number
                Returns grading result with subscores, weights, and total score

        Examples:
            julia --project -m LLMBenchMCPServer MyBenchmark
            julia --project -m LLMBenchMCPServer MyBenchmark --socket
            julia --project -m LLMBenchMCPServer MyBenchmark --direct  # Run without sandbox
            julia --project -m LLMBenchMCPServer MyBenchmark --bash-uid 1000
            julia --project -m LLMBenchMCPServer MyBenchmark --bash-env PATH=/custom/path --bash-env FOO=bar
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
    direct_mode = false  # New flag for direct execution
    bash_uid = nothing  # UID for bash session execution
    bash_env = Dict{String,String}()  # Environment variables for bash

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
        elseif args[i] == "--direct"
            direct_mode = true
            i += 1
        elseif args[i] == "--bash-uid" && i + 1 <= length(args)
            try
                bash_uid = parse(Int, args[i + 1])
            catch
                println("Warning: Invalid UID value: $(args[i + 1])")
            end
            i += 2
        elseif args[i] == "--bash-env" && i + 1 <= length(args)
            # Parse KEY=VALUE format
            env_arg = args[i + 1]
            if contains(env_arg, "=")
                key, value = split(env_arg, "=", limit=2)
                bash_env[String(key)] = String(value)
            else
                println("Warning: Invalid --bash-env format: $(env_arg) (expected KEY=VALUE)")
            end
            i += 2
        else
            println("Warning: Unknown option: $(args[i])")
            i += 1
        end
    end
    
    # If not in direct mode, re-launch ourselves in a sandbox
    if !direct_mode
        if verbose
            println("Launching LLMBenchMCPServer in sandbox...")
            println("Note: Sandbox mode requires Sandbox.jl from BinaryBuilder2 ecosystem")
        end
        return launch_in_sandbox(args)
    end
    
    # In direct mode, show a warning if verbose
    if verbose && direct_mode
        println("Running in DIRECT mode (no sandboxing)")
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
        # Try to load as a module first, then as a file
        mod = nothing
        mod_symbol = Symbol(module_name)
        
        # First try to load as a registered package/module
        try
            mod = Base.require(Main, mod_symbol)
        catch
            # If that fails, try to load as a local file
            if endswith(module_name, ".jl")
                # Load file directly
                Base.include(Main, module_name)
                # Extract module name from file
                file_mod_name = basename(module_name)[1:end-3]  # Remove .jl
                mod_symbol = Symbol(file_mod_name)
                if isdefined(Main, mod_symbol)
                    mod = getfield(Main, mod_symbol)
                end
            elseif isfile(module_name * ".jl")
                # Try adding .jl extension
                Base.include(Main, module_name * ".jl")
                mod_symbol = Symbol(module_name)
                if isdefined(Main, mod_symbol)
                    mod = getfield(Main, mod_symbol)
                end
            end
        end
        
        if mod === nothing
            throw(ArgumentError("Could not load module $module_name"))
        end

        # Set environment variables for benchmark access
        # Set workspace directory
        ENV["LLMBENCH_WORKSPACE"] = working_dir
        
        # Set bash UID if specified
        if bash_uid !== nothing
            ENV["LLMBENCH_BASH_UID"] = string(bash_uid)
        end
        
        # Set bash environment variables with a prefix
        for (key, value) in bash_env
            ENV["LLMBENCH_BASH_ENV_$key"] = value
        end
        
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
            include_basic_tools=include_basic_tools,
            bash_uid=bash_uid,
            bash_env=bash_env
        )

        if verbose
            println("Starting MCP server for $module_name")
            println("Working directory: $working_dir")
            if bash_uid !== nothing
                println("Bash UID: $bash_uid")
            end
            if !isempty(bash_env)
                println("Bash environment variables: $bash_env")
            end
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
