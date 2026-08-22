-- Fallback on bad answer from default upstream

local ffi = require('ffi')
local kres = require('kres')
ffi.cdef("void kr_server_selection_init(struct kr_query *qry);")

local M = {
	layer = {},
	timeout = 2 * sec,
	action = policy.FORWARD({'1.1.1.1', '9.9.9.10', '76.76.2.0', '86.54.11.100'})
}

local fallback = {}

local function do_fallback(state, req, qry)
	local key = tostring(req)
	if fallback[key] then
		return false
	end
	fallback[key] = true

	local qname = kres.dname2str(qry.sname)
	local qtype = kres.tostring.type[qry.stype]
	log_debug(ffi.C.LOG_GRP_POLICY, '[fallback] => fallback policy applied for %s %s', qname, qtype)

	-- Reset cache
	event.after(0, function()
		cache.clear(qname, true)
	end)

	-- Reset records selected for the failed top-level answer.
	if qry.cname_parent == nil then
		req.answ_selected.len = 0
	end
	req.auth_selected.len = 0
	req.add_selected.len = 0

	qry.flags.NO_NS_FOUND = false
	qry.flags.TCP = false

	-- Reset current forwarding
	req.selection_context.forwarding_targets.len = 0

	-- Reset failure counter
	req.count_fail_row = 0

	M.action(state, req)
	ffi.C.kr_server_selection_init(qry)

	return true
end

local function has_address_or_alias(pkt, qtype)
	if qtype ~= kres.type.A and qtype ~= kres.type.AAAA then
		return true
	end

	local records = pkt:section(kres.section.ANSWER)
	for index = 1, #records do
		local record_type = records[index].type
		if record_type == qtype
			or record_type == kres.type.CNAME
			or record_type == kres.type.DNAME then
			return true
		end
	end
	return false
end

-- Switch to fallback on timeout or all upstreams failing.
function M.layer.produce(state, req, pkt)
	local qry = req:current()
	if not qry or qry.flags.CACHED or not qry.flags.FORWARD then
		return state
	end

	local deadline = qry.creation_time_mono + M.timeout
	if ffi.C.kr_now() > deadline or qry.flags.NO_NS_FOUND then
		do_fallback(state, req, qry)
	end
	return state
end

-- Recheck negative replies and address replies without the requested RRset.
function M.layer.consume(state, req, pkt)
	local qry = req:current()
	if not qry or qry.flags.CACHED or not qry.flags.FORWARD then
		return state
	end

	if pkt:rcode() == kres.rcode.NOERROR
		and has_address_or_alias(pkt, qry.stype) then
		return state
	end

	if do_fallback(state, req, qry) then
		return kres.FAIL
	end
	return state
end

-- Switch to fallback after upstream fail
function M.layer.reset(state, req)
	local qry = req:current()
	if not qry or qry.flags.CACHED or not qry.flags.FORWARD
		or req.count_fail_row == 0 then
		return state
	end

	do_fallback(state, req, qry)
	return state
end

-- Finish for this request
function M.layer.finish(state, req)
	local key = tostring(req)
	fallback[key] = nil
	return state
end

return M
