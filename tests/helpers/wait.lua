--- Poll `condition()` until it returns truthy or `timeout_ms` elapses.
--- Returns the same boolean vim.wait would: true if condition became
--- truthy, false if the wait timed out.
return function(condition, timeout_ms)
	return vim.wait(timeout_ms or 2000, condition, 10)
end
