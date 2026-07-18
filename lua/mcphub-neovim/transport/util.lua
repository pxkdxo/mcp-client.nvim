--- Shared helpers for transport modules.
local M = {}

--- plenary.curl returns headers as an array of raw "Key: Value" lines
--- (not a table), since curl dumps them verbatim. Find a header by name,
--- case-insensitively, returning its value with surrounding whitespace
--- trimmed, or nil if absent.
function M.find_header(headers, name)
	if not headers then
		return nil
	end
	local lowered_name = name:lower()
	for _, line in ipairs(headers) do
		local key, value = line:match("^([^:]+):%s*(.*)$")
		if key and key:lower() == lowered_name then
			return (value:gsub("%s+$", ""))
		end
	end
	return nil
end

return M
