local buffer = require("string.buffer")
local ngx_re_find = ngx.re.find
local ai_plugin_ctx = require("kong.llm.plugin.ctx")

local _M = {
  NAME = "guard-prompt",
  STAGE = "REQ_TRANSFORMATION",
  }

local FILTER_OUTPUT_SCHEMA = {
  guarded = "boolean",
}

local _, set_ctx = ai_plugin_ctx.get_namespaced_accesors(_M.NAME, FILTER_OUTPUT_SCHEMA)

local EMPTY = {}


local function bad_request(msg)
  kong.log.debug(msg)
  return kong.response.exit(400, { error = { message = msg } })
end



local execute do
  local bad_format_error = "ai-prompt-guard only supports llm/v1/chat or llm/v1/completions prompts"

  -- Checks the prompt for the given patterns.
  -- _Note_: if a regex fails, it returns a 500, and exits the request.
  -- @tparam table request The deserialized JSON body of the request
  -- @tparam table conf The plugin configuration
  -- @treturn[1] table The decorated request (same table, content updated)
  -- @treturn[2] nil
  -- @treturn[2] string The error message
  function execute(request, conf)
    local collected_prompts
    local messages = request.messages

    -- concat all prompts into one string, if conversation history must be checked
    if type(messages) == "table" then
      local buf = buffer.new()
      -- Note allow_all_conversation_history means ignores history
      local just_pick_latest = conf.allow_all_conversation_history

      -- iterate in reverse so we get the latest user prompt first
      -- instead of the oldest one in history
      for i=#messages, 1, -1 do
        local v = messages[i]
        if type(v.role) ~= "string" then
          return nil, bad_format_error
        end
        if v.role == "user" or conf.match_all_roles then
          if type(v.content) ~= "string" then
            return nil, bad_format_error
          end
          buf:put(v.content)

          if just_pick_latest then
            break
          end

          buf:put(" ") -- put a seperator to avoid adhension of words
        end
      end

      collected_prompts = buf:get()

    elseif type(request.prompt) == "string" then
      collected_prompts = request.prompt

    else
      return nil, bad_format_error
    end

    if not collected_prompts then
      return nil, "no 'prompt' or 'messages' received"
    end


    -- check the prompt for explcit ban patterns
    for _, v in ipairs(conf.deny_patterns or EMPTY) do
      -- check each denylist; if prompt matches it, deny immediately
      local m, _, err = ngx_re_find(collected_prompts, v, "jo")
      if err then
        -- regex failed, that's an error by the administrator
        kong.log.err("bad regex pattern '", v ,"', failed to execute: ", err)
        return kong.response.exit(500)

      elseif m then
        return nil, "prompt pattern is blocked"
      end
    end


    if #(conf.allow_patterns or EMPTY) == 0 then
      -- no allow_patterns, so we're good
      return true
    end

    -- if any allow_patterns specified, make sure the prompt matches one of them
    for _, v in ipairs(conf.allow_patterns or EMPTY) do
      -- check each denylist; if prompt matches it, deny immediately
      local m, _, err = ngx_re_find(collected_prompts, v, "jo")

      if err then
        -- regex failed, that's an error by the administrator
        kong.log.err("bad regex pattern '", v ,"', failed to execute: ", err)
        return kong.response.exit(500)

      elseif m then
        return true  -- got a match so is allowed, exit early
      end
    end

    return false, "prompt doesn't match any allowed pattern"
  end
end

if _G._TEST then
  -- only if we're testing export this function (using a different name!)
  _M._execute = execute
end

function _M:run(conf)
  -- if plugin ordering was altered, receive the "decorated" request
  local request_body_table, source = ai_plugin_ctx.get_request_body_table_inuse()
  if not request_body_table then
    return bad_request("this LLM route only supports application/json requests")
  end

  kong.log.debug("using request body from source: ", source)

  -- run access handler
  local ok, err = execute(request_body_table, conf)
  if not ok then
    kong.log.debug(err)
    return bad_request("bad request") -- don't let users know 'ai-prompt-guard' is in use
  end

  set_ctx("guarded", true)

  return true
end

return _M
