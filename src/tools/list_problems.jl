"""
    ListProblemsTool

MCP tool to list available benchmark problems.
"""
struct ListProblemsTool <: ClaudeMCPTools.MCPTool
    list_fn::Union{Function, Nothing}
    working_dir::String

    function ListProblemsTool(list_fn::Union{Function, Nothing}=nothing;
                             working_dir::String=pwd())
        new(list_fn, working_dir)
    end
end

function ClaudeMCPTools.tool_schema(tool::ListProblemsTool)
    return Dict(
        "name" => "list_problems",
        "description" => "List all available benchmark problems",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict{String,Any}(),
            "required" => String[]
        )
    )
end

function ClaudeMCPTools.execute(tool::ListProblemsTool, params::Dict)
    # Call the list function
    if tool.list_fn !== nothing
        try
            problems = Base.invokelatest(tool.list_fn)

            # Format the response
            if isempty(problems)
                message = "No problems available."
            else
                message = "Available problems:\n" * join(["- $p" for p in problems], "\n")
            end

            return Dict(
                "content" => [Dict(
                    "type" => "text",
                    "text" => message
                )],
                "isError" => false
            )
        catch e
            io = IOBuffer()
            showerror(io, e, catch_backtrace())
            error_msg = "Failed to list problems:\n" * String(take!(io))

            return Dict(
                "content" => [Dict(
                    "type" => "text",
                    "text" => error_msg
                )],
                "isError" => true
            )
        end
    else
        return Dict(
            "content" => [Dict(
                "type" => "text",
                "text" => "No list_problems function configured"
            )],
            "isError" => true
        )
    end
end