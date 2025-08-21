"""
Setup Problem Tool for LLM Benchmark
"""

mutable struct SetupProblemTool <: ClaudeMCPTools.MCPTool
    setup_fn::Function
    working_dir::String
    
    function SetupProblemTool(setup_fn::Function; working_dir::String=pwd())
        new(setup_fn, working_dir)
    end
end

function ClaudeMCPTools.tool_schema(::SetupProblemTool)
    return Dict(
        "name" => "setup_problem",
        "description" => "Set up the problem environment and return the problem description",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "problem_id" => Dict(
                    "type" => "string",
                    "description" => "The problem identifier (optional)"
                )
            ),
            "required" => String[]
        )
    )
end

function ClaudeMCPTools.execute(tool::SetupProblemTool, params::Dict)
    problem_id = get(params, "problem_id", "")
    
    try
        # Call the setup function with the working directory and problem_id
        # Use invokelatest to handle world age issues when loading modules dynamically
        # Always pass both parameters if we have a problem_id
        # The function can have a default value for problem_id
        result = Base.invokelatest(tool.setup_fn, tool.working_dir, problem_id)
        
        # The setup function should return a problem description
        # Format it as a proper MCP response
        if isa(result, String)
            description = result
        elseif isa(result, Dict)
            # If it returns a dict, try to extract description
            description = get(result, "description", JSON.json(result))
        else
            description = string(result)
        end
        
        return Dict(
            "content" => [Dict(
                "type" => "text",
                "text" => description
            )],
            "isError" => false
        )
        
    catch e
        # Get a proper error message with backtrace
        io = IOBuffer()
        showerror(io, e, catch_backtrace())
        error_msg = "Failed to setup problem:\n" * String(take!(io))
        
        # Also print to stderr for debugging
        @error "Setup problem failed" exception=(e, catch_backtrace())
        
        return Dict(
            "content" => [Dict(
                "type" => "text",
                "text" => error_msg
            )],
            "isError" => true
        )
    end
end