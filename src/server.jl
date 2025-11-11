"""
LLM Benchmark MCP Server implementation
"""

using Sockets
using Scratch
using TOML
using Pkg
using UUIDs
using Dates

# Load Revise once per process using OncePerProcess
if VERSION < v"1.12"
    const load_revise = (args...,) -> error("Only supported on 1.12")
else
    const load_revise = Base.OncePerProcess{Union{Module,Nothing}}() do
        try
            # Use PkgId to load Revise
            revise_pkg = Base.PkgId(Base.UUID("295af30f-e4ad-537b-8983-00126c2a3abe"), "Revise")
            return Base.require(revise_pkg)
        catch e
            @warn "Failed to load Revise package" exception = e
            return nothing
        end
    end
end

"""
Move output directories to /tmp/output_dirs.
"""
function move_output_directories(output_dirs::Vector{String}, working_dir::String; verbose::Bool=false)
    if isempty(output_dirs)
        return
    end

    output_base = "/tmp/output_dirs"

    # Create the output base directory if it doesn't exist
    if !isdir(output_base)
        mkpath(output_base)
        if verbose
            println(stderr, "Created output directory: $output_base")
        end
    end

    # Move each specified directory
    for dir in output_dirs
        # Resolve relative paths from working_dir
        source_path = isabspath(dir) ? dir : joinpath(working_dir, dir)

        if isdir(source_path)
            # Get the basename for the destination
            dir_name = basename(source_path)
            dest_path = joinpath(output_base, dir_name)

            # If destination exists, create a unique name
            if ispath(dest_path)
                timestamp = Dates.format(Dates.now(), "yyyymmdd_HHMMSS_sss")
                dest_path = joinpath(output_base, "$(dir_name)_$(timestamp)")
            end

            try
                mv(source_path, dest_path)
                if verbose
                    println(stderr, "Moved directory: $source_path -> $dest_path")
                end
            catch e
                println(stderr, "Warning: Failed to move directory $source_path: $e")
            end
        else
            if verbose
                println(stderr, "Warning: Directory not found: $source_path")
            end
        end
    end
end

"""
Handle a single client connection.
"""
function handle_client_connection(client::IO, server::ClaudeMCPTools.MCPServer;
    verbose::Bool=false, use_revise::Bool=false,
    connection_info::String="")
    if verbose && !isempty(connection_info)
        @info "Connection established: $connection_info"
    end

    try
        while isopen(client)
            # Read a line (JSON-RPC message)
            line = readline(client)
            # For stdio (stdin/stdout), empty line means EOF - exit
            # For sockets, readline will block until data arrives
            if isempty(line)
                if client === stdin || client === stdout
                    # stdin/stdout - empty means client disconnected
                    break
                end
                # For other clients, continue waiting (shouldn't normally get here)
                continue
            end

            # Call Revise before processing if requested
            if use_revise
                revise_mod = load_revise()
                if revise_mod !== nothing
                    try
                        Base.invokelatest(revise_mod.revise)
                        if verbose
                            @debug "Revise.revise() called before processing request"
                        end
                    catch e
                        if verbose
                            @warn "Revise.revise() failed" exception = e
                        end
                    end
                end
            end

            # Parse and handle the request
            request = nothing
            try
                request = JSON.parse(line)

                # Log incoming request if verbose
                if verbose
                    println(stderr, "\n=== Received request ===")
                    println(stderr, "Connection: $connection_info")
                    println(stderr, "Request:")
                    println(stderr, JSON.json(request, 2))  # Pretty print with indent
                    println(stderr, "=======================\n")
                    flush(stderr)
                end

                # Check if this is a notification (no id field means it's a notification)
                is_notification = !haskey(request, "id")

                # Handle notifications - they don't need responses
                if is_notification
                    if verbose
                        @info "Received notification (no response needed)" connection = connection_info
                    end
                    continue
                end

                # For requests (not notifications), handle normally
                response = if use_revise
                    Base.invokelatest(ClaudeMCPTools.handle_request, server, request)
                else
                    ClaudeMCPTools.handle_request(server, request)
                end

                # Convert response to JSON
                json_response = JSON.json(response)

                # Log outgoing response if verbose
                if verbose
                    println(stderr, "\n=== Sending response ===")
                    println(stderr, "Connection: $connection_info")
                    println(stderr, "Response:")
                    println(stderr, json_response)
                    println(stderr, "======================\n")
                    flush(stderr)
                end

                # Send response
                # In stdio mode, read from stdin but write to stdout
                output_stream = (client === stdin) ? stdout : client
                println(output_stream, json_response)
                flush(output_stream)
            catch e
                # Only send error response if it's not a notification
                if request !== nothing && haskey(request, "id")
                    error_response = Dict(
                        "jsonrpc" => "2.0",
                        "error" => Dict(
                            "code" => -32603,
                            "message" => "Internal error: $(string(e))"
                        ),
                        "id" => request["id"]
                    )
                    # In stdio mode, read from stdin but write to stdout
                    output_stream = (client === stdin) ? stdout : client
                    println(output_stream, JSON.json(error_response))
                    flush(output_stream)
                end
            end
        end
    catch e
        if !(e isa EOFError || e isa Base.IOError)
            @error "Error handling client" exception = e
        end
    finally
        # Don't close stdin/stdout - only close actual client sockets
        if client !== stdin && client !== stdout
            close(client)
        end
        if verbose && !isempty(connection_info)
            @info "Connection closed: $connection_info"
        end
    end
end

"""
Run the Unix socket server with optional Revise support.
"""
function run_server_multi_instance(setup_fn::Union{Function,Nothing}, grade_fn::Union{Function,Nothing},
    list_fn::Union{Function,Nothing},
    socket_path::String, base_working_dir::String;
    verbose::Bool=false, use_revise::Bool=false,
    include_basic_tools::Bool=true, bash_uid::Union{Int,Nothing}=nothing,
    bash_env::Dict{String,String}=Dict{String,String}())
    # Clean up existing socket if it exists
    # Use ispath() not isfile() for Unix domain sockets
    if ispath(socket_path)
        rm(socket_path)
    end

    # Create the Unix socket
    socket = Sockets.listen(socket_path)

    if verbose
        @info "MCP server (multi-instance) listening on Unix socket: $socket_path"
    end

    # Use common accept loop with multi-instance mode
    accept_connections(socket, "socket: $socket_path";
        multi_instance=true,
        base_working_dir=base_working_dir,
        setup_fn=setup_fn,
        grade_fn=grade_fn,
        list_fn=list_fn,
        include_basic_tools=include_basic_tools,
        bash_uid=bash_uid,
        bash_env=bash_env,
        verbose=verbose,
        use_revise=use_revise)
end

"""
    accept_connections(socket_server, connection_type::String;
                      server::Union{ClaudeMCPTools.MCPServer, Nothing}=nothing,
                      multi_instance::Bool=false,
                      base_working_dir::String="",
                      setup_fn=nothing, grade_fn=nothing, list_fn=nothing,
                      include_basic_tools::Bool=true,
                      bash_uid::Union{Int, Nothing}=nothing,
                      bash_env::Dict{String,String}=Dict{String,String}(),
                      verbose::Bool=false, use_revise::Bool=false)

Common function to accept connections and handle them.
`connection_type` is a description like "socket: /path" or "fd3 (sandbox mode)"
If `multi_instance` is true, creates a new server instance for each connection.
"""
function accept_connections(socket_server, connection_type::String;
    server::Union{ClaudeMCPTools.MCPServer,Nothing}=nothing,
    multi_instance::Bool=false,
    base_working_dir::String="",
    setup_fn=nothing, grade_fn=nothing, list_fn=nothing,
    include_basic_tools::Bool=true,
    bash_uid::Union{Int,Nothing}=nothing,
    bash_env::Dict{String,String}=Dict{String,String}(),
    verbose::Bool=false, use_revise::Bool=false)

    # Validate arguments
    if !multi_instance && server === nothing
        error("Single-instance mode requires a server instance")
    end
    if multi_instance && base_working_dir == ""
        error("Multi-instance mode requires base_working_dir")
    end

    connection_count = Ref(0)

    try
        while true
            # Accept connection
            client = Sockets.accept(socket_server)
            connection_count[] += 1
            conn_id = connection_count[]

            if multi_instance
                # Create a unique subdirectory for this connection
                timestamp = Dates.format(Dates.now(), "yyyymmdd_HHMMSS_sss")
                instance_dir = joinpath(base_working_dir, "instance_$(timestamp)_$(conn_id)")
                mkpath(instance_dir)

                if verbose
                    @info "Accepted connection #$conn_id on $connection_type, working directory: $instance_dir"
                end

                # Create a new server instance for this connection
                instance_server = LLMBenchServer(
                    name="LLMBenchServer_$(conn_id)",
                    setup_fn=setup_fn,
                    grade_fn=grade_fn,
                    list_fn=list_fn,
                    working_dir=instance_dir,
                    include_basic_tools=include_basic_tools,
                    bash_uid=bash_uid,
                    bash_env=bash_env
                )

                # Handle client with its own server instance
                @async handle_client_connection(client, instance_server;
                    verbose=verbose, use_revise=use_revise,
                    connection_info="multi-instance connection #$conn_id via $connection_type, directory: $instance_dir")
            else
                if verbose
                    @info "Accepted connection #$conn_id on $connection_type"
                end

                # Handle client with shared server instance
                @async handle_client_connection(client, server;
                    verbose=verbose, use_revise=use_revise,
                    connection_info="connection #$conn_id via $connection_type")
            end
        end
    catch e
        if !isa(e, InterruptException)
            println(stderr, "Error in server accept loop: $e")
            throw(e)
        end
    finally
        close(socket_server)
    end
end

function run_server_with_revise(server::ClaudeMCPTools.MCPServer, socket_path::String;
    verbose::Bool=false, use_revise::Bool=false)
    # Clean up existing socket if it exists
    # Use ispath() not isfile() for Unix domain sockets
    if ispath(socket_path)
        rm(socket_path)
    end

    # Create the Unix socket
    socket = Sockets.listen(socket_path)

    if verbose
        @info "MCP server listening on Unix socket: $socket_path"
    end

    # Use common accept loop
    accept_connections(socket, "socket: $socket_path";
        server=server,
        verbose=verbose, use_revise=use_revise)
end

"""
    run_server_from_fd3(; server::Union{ClaudeMCPTools.MCPServer, Nothing}=nothing,
                        multi_instance::Bool=false,
                        base_working_dir::String="",
                        setup_fn=nothing, grade_fn=nothing, list_fn=nothing,
                        include_basic_tools::Bool=true,
                        bash_uid::Union{Int, Nothing}=nothing,
                        bash_env::Dict{String,String}=Dict{String,String}(),
                        verbose::Bool=false, use_revise::Bool=false)

Run the MCP server using a server socket passed as file descriptor 3.
This is used when running inside a sandbox where the parent process passes the server socket.
Supports both single-instance (with server) and multi-instance modes.
"""
function run_server_from_fd3(; server::Union{ClaudeMCPTools.MCPServer,Nothing}=nothing,
    multi_instance::Bool=false,
    base_working_dir::String="",
    setup_fn=nothing, grade_fn=nothing, list_fn=nothing,
    include_basic_tools::Bool=true,
    bash_uid::Union{Int,Nothing}=nothing,
    bash_env::Dict{String,String}=Dict{String,String}(),
    verbose::Bool=false, use_revise::Bool=false)
    # Create a PipeServer from file descriptor 3
    # fd 3 because: 0=stdin, 1=stdout, 2=stderr, 3=our server socket
    # The socket was bound in parent, now we listen
    socket_server = Sockets.PipeServer(RawFD(3))
    listen(socket_server)

    if verbose
        @info "MCP server listening via file descriptor 3" multi_instance
    end

    # Use common accept loop
    accept_connections(socket_server, "fd3 (sandbox mode)";
        server=server,
        multi_instance=multi_instance,
        base_working_dir=base_working_dir,
        setup_fn=setup_fn,
        grade_fn=grade_fn,
        list_fn=list_fn,
        include_basic_tools=include_basic_tools,
        bash_uid=bash_uid,
        bash_env=bash_env,
        verbose=verbose,
        use_revise=use_revise)
end

"""
    LLMBenchServer

An MCP server specifically for LLM benchmarking with setup and grade functions.
"""
function LLMBenchServer(;
    name::String="LLMBenchMCPServer",
    version::String="0.1.0",
    setup_fn::Union{Function,Nothing}=nothing,
    grade_fn::Union{Function,Nothing}=nothing,
    list_fn::Union{Function,Nothing}=nothing,
    working_dir::String=pwd(),
    include_basic_tools::Bool=true,
    bash_uid::Union{Int,Nothing}=nothing,
    bash_env::Dict{String,String}=Dict{String,String}()
)
    # Create base MCP server
    server = ClaudeMCPTools.MCPServer(name=name, version=version)

    # Add basic tools if requested
    if include_basic_tools
        ClaudeMCPTools.register_tool!(server, "bash", ClaudeMCPTools.BashTool(
            working_dir=working_dir,
            env=bash_env,
            uid=bash_uid
        ))
        ClaudeMCPTools.register_tool!(server, "str_replace_editor",
            ClaudeMCPTools.StrReplaceEditorTool(base_path=working_dir, uid=bash_uid))
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

    # Add list_problems tool if function provided
    if list_fn !== nothing
        ClaudeMCPTools.register_tool!(server, "list_problems",
            ListProblemsTool(list_fn, working_dir=working_dir))
    end

    return server
end

# Main entry point for the LLMBenchMCPServer.
# Usage: julia --project -m LLMBenchMCPServer ModuleName [--workspace /path]
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
                               Use "auto" to auto-detect module from problem_id prefix

        Options:
            --workspace PATH      Working directory (default: current directory)
            --socket            Run server on Unix domain socket (creates socket in /tmp)
            --bind-socket PATH  Run server on Unix domain socket at specified path
            --fd3                Use file descriptor 3 as the socket (for sandbox mode)
            --revise            Load Revise.jl and auto-reload code changes
            --no-basic-tools    Disable basic tools (bash, str_replace_editor)
            --verbose           Enable verbose output
            --multi             Multi-instance mode: each connection gets a new subdirectory
            --direct            Run directly without sandboxing (default: run in sandbox)
            --bash-uid UID      Set UID for bash session execution (e.g., 1000)
            --bash-env KEY=VAL  Set environment variables for bash (can be used multiple times)
            --forward-ssh       Forward SSH agent authentication to sandbox
            --sandbox-bash      Launch bash shell in sandbox environment (for debugging)
            --output-dirs DIRS  Comma-separated list of directories to move to /tmp/output_dirs at end
            --help, -h          Show this help message

        The specified module should export:
            - setup_problem(workdir::String) -> String/Dict
                Returns the problem description

            - grade(workdir::String, transcript::String) -> Dict/Number
                Returns grading result with subscores, weights, and total score

        Examples:
            julia --project -m LLMBenchMCPServer MyBenchmark
            julia --project -m LLMBenchMCPServer auto  # Auto-detect module from problem_id
            julia --project -m LLMBenchMCPServer MyBenchmark --socket
            julia --project -m LLMBenchMCPServer MyBenchmark --direct  # Run without sandbox
            julia --project -m LLMBenchMCPServer MyBenchmark --bash-uid 1000
            julia --project -m LLMBenchMCPServer MyBenchmark --bash-env PATH=/custom/path --bash-env FOO=bar
        """)
        return 0
    end

    # Parse arguments
    module_name = args[1]
    working_dir = get(ENV, "LLMBENCH_WORKSPACE", pwd())
    use_socket = false
    socket_path = ""  # For --bind-socket
    use_fd3 = false  # New flag for using fd 3 as socket
    use_revise = false
    include_basic_tools = true
    verbose = false
    direct_mode = false  # New flag for direct execution
    bash_uid = nothing  # UID for bash session execution
    bash_env = Dict{String,String}()  # Environment variables for bash
    auto_mode = (module_name == "auto")  # Check if we're in auto-detect mode
    multi_mode = false  # New flag for multi-instance mode
    forward_ssh = false  # Forward SSH agent to sandbox
    output_dirs = String[]  # Directories to move to /tmp/output_dirs at end

    i = 2
    while i <= length(args)
        if args[i] == "--workspace" && i + 1 <= length(args)
            working_dir = args[i+1]
            i += 2
        elseif args[i] == "--socket"
            use_socket = true
            i += 1
        elseif args[i] == "--bind-socket" && i + 1 <= length(args)
            use_socket = true
            socket_path = args[i+1]
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
                bash_uid = parse(Int, args[i+1])
            catch
                println(stderr, "Warning: Invalid UID value: $(args[i + 1])")
            end
            i += 2
        elseif args[i] == "--bash-env" && i + 1 <= length(args)
            # Parse KEY=VALUE format
            env_arg = args[i+1]
            if contains(env_arg, "=")
                key, value = split(env_arg, "=", limit=2)
                bash_env[String(key)] = String(value)
            else
                println(stderr, "Warning: Invalid --bash-env format: $(env_arg) (expected KEY=VALUE)")
            end
            i += 2
        elseif args[i] == "--multi"
            multi_mode = true
            i += 1
        elseif args[i] == "--forward-ssh"
            forward_ssh = true
            i += 1
        elseif args[i] == "--fd3"
            use_fd3 = true
            use_socket = true  # fd3 implies socket mode
            i += 1
        elseif args[i] == "--output-dirs" && i + 1 <= length(args)
            # Parse comma-separated list of directories
            dirs_arg = args[i+1]
            output_dirs = String[strip(d) for d in split(dirs_arg, ",") if !isempty(strip(d))]
            i += 2
        elseif args[i] == "--sandbox-bash"
            # Launch bash shell in sandbox for debugging
            if !direct_mode
                # Try to load Sandbox if not already loaded
                if !hasmethod(has_sandbox_support, Tuple{})
                    if verbose
                        println(stderr, "Loading Sandbox.jl for --sandbox-bash...")
                    end

                    try
                        Base.require(Main, :Sandbox)
                        Base.require(Main, :BinaryBuilder2)

                        if !Base.invokelatest(has_sandbox_support)
                            println(stderr, "Error: Failed to load Sandbox extension for --sandbox-bash")
                            return Cint(1)
                        end

                        if verbose
                            println(stderr, "✓ Sandbox.jl loaded")
                        end
                    catch e
                        if e isa ArgumentError && occursin("is required but does not seem to be installed", string(e))
                            println(stderr, "Error: Sandbox.jl is not installed: $e")
                        else
                            println(stderr, "Error: Could not load Sandbox.jl: $e")
                        end
                        println(stderr, "Please run from a ClaudeBox environment or install Sandbox.jl")
                        return Cint(1)
                    end
                end
                return Base.invokelatest(launch_sandbox_bash, args, working_dir, verbose, forward_ssh)
            else
                println(stderr, "Error: --sandbox-bash requires sandbox mode (remove --direct)")
                return Cint(1)
            end
        else
            println(stderr, "Warning: Unknown option: $(args[i])")
            i += 1
        end
    end

    # If not in direct mode, attempt to load Sandbox and re-launch in sandbox
    if !direct_mode
        # Try to load Sandbox automatically if not already loaded
        # Check if has_sandbox_support has methods (i.e., extension is loaded)
        if !hasmethod(has_sandbox_support, Tuple{})
            if verbose
                println(stderr, "Sandbox mode requested, attempting to load Sandbox.jl...")
            end

            try
                # Try to load Sandbox
                Base.require(Main, :Sandbox)
                # Also load BinaryBuilder2 to trigger the extension
                Base.require(Main, :BinaryBuilder2)

                # Check if extension loaded successfully by calling has_sandbox_support
                if !Base.invokelatest(has_sandbox_support)
                    println(
                        stderr,
                        """
        Error: Failed to load Sandbox extension.

        Options:
        1. Run with --direct flag to execute without sandboxing:
           julia --project -m LLMBenchMCPServer <args> --direct

        2. Run from within ClaudeBox environment where Sandbox.jl is available
        """
                    )
                    return Cint(1)
                end

                if verbose
                    println(stderr, "✓ Sandbox.jl loaded successfully")
                end
            catch e
                # Check if this is a "package not installed" error
                if e isa ArgumentError && occursin("is required but does not seem to be installed", string(e))
                    println(
                        stderr,
                        """
        Error: Sandbox.jl is not installed: $e

        Options:
        1. Run with --direct flag to execute without sandboxing:
           julia --project -m LLMBenchMCPServer <args> --direct

        2. Install Sandbox.jl (requires BinaryBuilder2 ecosystem)

        3. Run from within ClaudeBox environment where Sandbox.jl is available
        """
                    )
                else
                    # Some other error during loading
                    println(stderr, "Error: Could not load Sandbox.jl: $e")
                    if verbose
                        # Show full backtrace in verbose mode
                        Base.showerror(stderr, e, catch_backtrace())
                        println(stderr)
                    end
                end
                return Cint(1)
            end
        end

        if verbose
            println(stderr, "Launching LLMBenchMCPServer in sandbox...")
        end
        return Base.invokelatest(launch_in_sandbox, args, use_socket, socket_path, working_dir, verbose, forward_ssh)
    end

    # In direct mode, show a warning if verbose
    if verbose && direct_mode
        println(stderr, "Running in DIRECT mode (no sandboxing)")
    end

    # Load Revise if requested
    if use_revise
        try
            # Load Revise dynamically
            Base.require(Main, :Revise)
            if verbose
                println(stderr, "Revise.jl loaded for auto-reloading")
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

    # Handle module loading based on mode
    try
        mod = nothing
        setup_fn = nothing
        grade_fn = nothing
        list_fn = nothing

        if auto_mode
            # In auto mode, create wrapper functions that dynamically load modules
            if verbose
                println(stderr, "Auto mode enabled - modules will be loaded based on problem_id prefix")
            end

            # Create a wrapper function for setup_problem that auto-detects the module
            function auto_setup_problem(workdir::String, problem_id::String="")
                if isempty(problem_id)
                    throw(ArgumentError("problem_id is required in auto mode. Format: ModuleName-problem_id"))
                end

                # Extract module name from problem_id
                parts = split(problem_id, "-", limit=2)
                if length(parts) < 2
                    throw(ArgumentError("Invalid problem_id format. Expected: ModuleName-problem_id, got: $problem_id"))
                end

                mod_name = String(parts[1])
                clean_problem_id = String(parts[2])

                # Load the module (let errors propagate naturally)
                mod_symbol = Symbol(mod_name)
                target_mod = Base.require(Main, mod_symbol)

                # Check if the module has setup_problem
                if !isdefined(target_mod, :setup_problem)
                    throw(ErrorException("Module $mod_name does not export setup_problem function"))
                end

                # Call the module's setup_problem with the clean problem_id
                setup_fn = getfield(target_mod, :setup_problem)
                return Base.invokelatest(setup_fn, workdir, clean_problem_id)
            end

            # Create a wrapper function for grade that auto-detects the module
            function auto_grade(workdir::String, transcript::String, problem_id::String="")
                if isempty(problem_id)
                    throw(ArgumentError("problem_id is required in auto mode. Format: ModuleName-problem_id"))
                end

                # Extract module name from problem_id
                parts = split(problem_id, "-", limit=2)
                if length(parts) < 2
                    throw(ArgumentError("Invalid problem_id format. Expected: ModuleName-problem_id, got: $problem_id"))
                end

                mod_name = String(parts[1])
                clean_problem_id = String(parts[2])

                # Load the module (let errors propagate naturally)
                mod_symbol = Symbol(mod_name)
                target_mod = Base.require(Main, mod_symbol)

                # Check if the module has grade
                if !isdefined(target_mod, :grade)
                    throw(ErrorException("Module $mod_name does not export grade function"))
                end

                # Call the module's grade with the clean problem_id
                grade_fn = getfield(target_mod, :grade)
                return Base.invokelatest(grade_fn, workdir, transcript, clean_problem_id)
            end

            # Create a wrapper function for list_problems that lists from all available modules
            function auto_list_problems()
                all_problems = Vector{Any}()  # Can contain Strings or Dicts
                checked_modules = Set{Symbol}()

                # Get packages from the current environment
                for env in Base.load_path()
                    # Get project file if it exists
                    project_file = Base.env_project_file(env)
                    if project_file isa String && isfile(project_file)
                        # Parse the project file to get dependencies
                        d = Base.parsed_toml(project_file)
                        deps = get(d, "deps", Dict{String,Any}())::Dict{String,Any}

                        # Try each dependency
                        for (pkg_name, _) in deps
                            pkg_symbol = Symbol(pkg_name)

                            # Skip if already checked
                            if pkg_symbol in checked_modules
                                continue
                            end
                            push!(checked_modules, pkg_symbol)

                            # Try to load the module and check for list_problems
                            try
                                # Use Base.require to properly load the module
                                mod = Base.require(Main, pkg_symbol)

                                # Check if the module has list_problems function
                                if isdefined(mod, :list_problems)
                                    list_fn = getfield(mod, :list_problems)
                                    problems = Base.invokelatest(list_fn)
                                    # Add module prefix to each problem
                                    for problem in problems
                                        # Handle both old (String) and new (Dict) formats
                                        problem_id = problem isa Dict ? get(problem, "id", string(problem)) : string(problem)
                                        # Create prefixed problem with all metadata
                                        if problem isa Dict
                                            prefixed_problem = copy(problem)
                                            prefixed_problem["id"] = "$pkg_name-$problem_id"
                                            push!(all_problems, prefixed_problem)
                                        else
                                            push!(all_problems, "$pkg_name-$problem_id")
                                        end
                                    end
                                    if verbose
                                        println(stderr, "Found $(length(problems)) problems in module $pkg_name")
                                    end
                                end
                            catch e
                                # Skip modules that can't be loaded or don't have benchmarks
                                if verbose && !occursin("not found", string(e))
                                    println(stderr, "Note: Module $pkg_name doesn't provide benchmarks or failed to load")
                                end
                            end
                        end
                    end
                end

                # Also check already loaded modules in Main
                for name in names(Main; all=true, imported=true)
                    if !(name in checked_modules) && isdefined(Main, name)
                        obj = getfield(Main, name)
                        if isa(obj, Module) && obj !== Main && obj !== Base && obj !== Core
                            # Check if the module has list_problems function
                            if isdefined(obj, :list_problems)
                                try
                                    list_fn = getfield(obj, :list_problems)
                                    problems = Base.invokelatest(list_fn)
                                    # Add module prefix to each problem
                                    module_name = string(nameof(obj))
                                    for problem in problems
                                        # Handle both old (String) and new (Dict) formats
                                        problem_id = problem isa Dict ? get(problem, "id", string(problem)) : string(problem)
                                        # Create prefixed problem with all metadata
                                        if problem isa Dict
                                            prefixed_problem = copy(problem)
                                            prefixed_problem["id"] = "$module_name-$problem_id"
                                            push!(all_problems, prefixed_problem)
                                        else
                                            push!(all_problems, "$module_name-$problem_id")
                                        end
                                    end
                                    if verbose
                                        println(stderr, "Found $(length(problems)) problems in loaded module $module_name")
                                    end
                                catch e
                                    # Skip modules that fail to list problems
                                    if verbose
                                        println(stderr, "Warning: Failed to list problems from module $(nameof(obj)): $e")
                                    end
                                end
                            end
                        end
                    end
                end

                return all_problems
            end

            # Set the wrapper functions
            setup_fn = auto_setup_problem
            grade_fn = auto_grade
            list_fn = auto_list_problems

        else
            # Normal mode - load the specified module
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

            # Extract functions from the loaded module
            if isdefined(mod, :setup_problem)
                setup_fn = getfield(mod, :setup_problem)
                if verbose
                    println(stderr, "Found setup_problem function in $module_name")
                end
            else
                println(stderr, "Warning: No setup_problem function found in $module_name")
            end

            if isdefined(mod, :grade)
                grade_fn = getfield(mod, :grade)
                if verbose
                    println(stderr, "Found grade function in $module_name")
                end
            else
                println(stderr, "Warning: No grade function found in $module_name")
            end

            if isdefined(mod, :list_problems)
                list_fn = getfield(mod, :list_problems)
                if verbose
                    println(stderr, "Found list_problems function in $module_name")
                end
            else
                if verbose
                    println(stderr, "Warning: No list_problems function found in $module_name")
                end
            end
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

        # Create and run the server
        server = LLMBenchServer(
            name="$module_name-MCP",
            version="1.0.0",
            setup_fn=setup_fn,
            grade_fn=grade_fn,
            list_fn=list_fn,
            working_dir=working_dir,
            include_basic_tools=include_basic_tools,
            bash_uid=bash_uid,
            bash_env=bash_env
        )

        if verbose
            println(stderr, "Starting MCP server for $module_name")
            println(stderr, "Working directory: $working_dir")
            if bash_uid !== nothing
                println(stderr, "Bash UID: $bash_uid")
            end
            if !isempty(bash_env)
                println(stderr, "Bash environment variables: $bash_env")
            end
            println(stderr, "Tools registered: $(keys(server.tools))")
        end

        # Run the server in appropriate mode
        if use_socket
            # Handle fd3 mode differently
            if use_fd3
                # In fd3 mode, we use the socket passed as file descriptor 3
                if verbose
                    println(stderr, "Using socket from file descriptor 3")
                end
                # Don't print socket path in fd3 mode - it's handled by parent
            else
                # Use provided socket path or generate a unique one
                if isempty(socket_path)
                    # Generate a unique socket path in /tmp
                    timestamp = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
                    pid = getpid()
                    socket_path = "/tmp/mcp_$(module_name)_$(timestamp)_$(pid).sock"
                end

                println(stderr, "Socket path: $socket_path")
            end

            # Run server with appropriate method
            if use_fd3
                # Use file descriptor 3 for the server socket
                # Supports both single and multi-instance modes
                run_server_from_fd3(
                    server=multi_mode ? nothing : server,
                    multi_instance=multi_mode,
                    base_working_dir=working_dir,
                    setup_fn=setup_fn,
                    grade_fn=grade_fn,
                    list_fn=list_fn,
                    include_basic_tools=include_basic_tools,
                    bash_uid=bash_uid,
                    bash_env=bash_env,
                    verbose=verbose,
                    use_revise=use_revise)
            else
                # Run with normal socket file
                try
                    if multi_mode
                        # Multi-instance mode: each connection gets its own subdirectory
                        # Note: setup_fn and grade_fn can be nothing if not found in module
                        run_server_multi_instance(setup_fn, grade_fn, list_fn, socket_path, working_dir;
                            verbose=verbose, use_revise=use_revise,
                            include_basic_tools=include_basic_tools,
                            bash_uid=bash_uid, bash_env=bash_env)
                    else
                        # Single instance mode: all connections share the same server
                        run_server_with_revise(server, socket_path, verbose=verbose, use_revise=use_revise)
                    end
                finally
                    # Ensure socket is cleaned up even on error
                    # Note: Use ispath() not isfile() for Unix domain sockets
                    if ispath(socket_path)
                        rm(socket_path)
                        if verbose
                            println(stderr, "Cleaned up socket: $socket_path")
                        end
                    end
                end
            end
        else
            # Stdio mode - use the same handler as socket mode for consistency
            # This ensures notifications are handled properly
            handle_client_connection(stdin, server, verbose=verbose, use_revise=use_revise,
                connection_info="stdio")
        end

    catch e
        println(stderr, "Error: $e")
        return 1
    finally
        # Move output directories to /tmp/output_dirs if specified
        move_output_directories(output_dirs, working_dir; verbose=verbose)
    end

    return 0
end

# Export a regular main function for programmatic use
const main = @main
export main
