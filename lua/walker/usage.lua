-- Accounting is explicit about estimates and missing provider information.
local M = {}
function M.new()
  return { total_tokens = 0, calls = 0, estimated = false, cost = 0, cost_known = true }
end

local function number(value)
  return type(value) == "number" and value >= 0 and value < math.huge and value == math.floor(value)
end

function M.add(usage, report, pricing, model)
  if not number(report.total_tokens) then return nil, "Invalid total token usage" end
  for _, key in ipairs({ "input_tokens", "output_tokens", "cached_tokens", "reasoning_tokens" }) do
    if report[key] ~= nil and not number(report[key]) then return nil, "Invalid " .. key end
  end
  if report.cached_tokens and (not report.input_tokens or report.cached_tokens > report.input_tokens) then
    return nil, "Invalid cached token usage"
  end
  usage.total_tokens = usage.total_tokens + report.total_tokens
  usage.calls = usage.calls + 1
  usage.estimated = usage.estimated or report.estimated == true
  for _, key in ipairs({ "input_tokens", "output_tokens", "cached_tokens", "reasoning_tokens" }) do
    if report[key] ~= nil then usage[key] = (usage[key] or 0) + report[key]
    else usage[key .. "_missing"] = true end
  end
  local valid_price = pricing and pricing.model == model and report.input_tokens and report.output_tokens
    and report.cached_tokens ~= nil and not report.estimated
  if valid_price then
    usage.cost = usage.cost + ((report.input_tokens - report.cached_tokens) * pricing.input_per_million
      + report.cached_tokens * pricing.cached_input_per_million
      + report.output_tokens * pricing.output_per_million) / 1000000
    usage.currency = pricing.currency
  else
    usage.cost_known = false
  end
  return true
end

function M.summary(usage, budget)
  local lines = { string.format("%d / %d tokens (task)%s", usage.total_tokens, budget, usage.estimated and " ~" or "") }
  if usage.estimated then lines[#lines + 1] = "Includes estimated usage" end
  if usage.incomplete then lines[#lines + 1] = "Unreported charges may exist" end
  return lines
end

function M.lines(usage, budget)
  local lines = { "Tokens used: " .. usage.total_tokens .. (usage.estimated and " (includes estimates)" or "") }
  for _, field in ipairs({ { "Input", "input_tokens" }, { "Cached input", "cached_tokens" }, { "Output", "output_tokens" }, { "Reasoning*", "reasoning_tokens" } }) do
    if usage[field[2]] then
      lines[#lines + 1] = field[1] .. ": " .. usage[field[2]] .. (usage[field[2] .. "_missing"] and " (partial)" or "")
    end
  end
  if budget then lines[#lines + 1] = "Task budget left: " .. math.max(0, budget - usage.total_tokens) end
  lines[#lines + 1] = usage.cost_known and usage.calls > 0
    and string.format("Est. cost: %s %.6f", usage.currency or "", usage.cost) or "Est. cost: unavailable"
  if usage.incomplete then lines[#lines + 1] = "Unreported charges may exist" end
  return lines
end
return M
