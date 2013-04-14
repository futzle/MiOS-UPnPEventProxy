#!/usr/bin/lua
--[[

	UPnP event proxy
	
	Copyright 2013 Deborah Pickett

	Parts of this program have been modified from the Luasocket library
	(http://w3.impa.br/~diego/software/luasocket/), released under the MIT licence.

	Version 0.1 2013-03-17 API version 1
	Version 0.1 2013-04-07 API version 2 (locking)
	Version 0.1 2013-04-09 API version 3 (locking replaced with random retries)

	This program listens on a TCP port (2529) for a subset of HTTP requests.
	
	GET /version HTTP/1.1
	Returns 200 OK, and the current API version of this program.

	PUT /upnp/event/[SID] HTTP/1.1
	Request that the proxy send notifications for the subscription [SID]
	to a nominated MiOS device.  Notifications are sent when a variable's
	value is sent by the UPnP device.
		<subscription expiry="timestamp">
			<variable name="UPnPVariableName" host="localhost" deviceId="123"
				serviceId="serviceWithAction" action="deviceActionName"
				parameter="deviceActionParameter"
				sidParameter="deviceActionParameter"
			/>
			<!-- more <variable> entries here. -->
		</subscription>
		Parameters:
			expiry: os.time() before which renewal must happen.
			name: the UPnP variable that the device is interested in.
			host: the address to forward the event to.  Defaults to localhost.
			deviceId: the device number that wants to be informed of the event.
			serviceId: the service Id of the action to invoke.
			action: the name of the action to invoke on the target device.
			parameter: the name of the parameter that will contain the value of the variable
			sidParameter: the name of the parameter that will contain the SID.

	DELETE /upnp/event/[SID] HTTP/1.1
	Request that this program no longer forwards events for subscription [SID].

	NOTIFY /upnp/event HTTP/1.1
	Sent by the UPnP device.  Format is as specified in the UPnP spec.
	Events that are subscribed to will be forwarded to the previously registered
	device with the registered action.
]]

local socket = require('socket')
local url = require('socket.url')
local http = require('socket.http')
local ltn12 = require('ltn12')
local lxp = require('lxp')

local API_VERSION = "3"
local LISTEN_PORT = 2529
local LISTEN_BACKLOG = 5
local LISTEN_TIMEOUT = 10

local subscriptions = {}
local notificationQueue = {}

function log(s)
	print(s)
end

-- Parse the HTTP request line.
-- Returns the method and the path (split at / characters)
function readStatusLine(c)
	local statusLine = c:receive('*l')
	local method, path = statusLine:match("^(%u+) ([^ ]+) HTTP/1.[01]")
	if (statusLine:match("^GET ")) then
		return "GET", url.parse_path(path)
	elseif (statusLine:match("^PUT ")) then
		return "PUT", url.parse_path(path)
	elseif (statusLine:match("^NOTIFY ")) then
		return "NOTIFY", url.parse_path(path)
	elseif (statusLine:match("^DELETE ")) then
		return "DELETE", url.parse_path(path)
	else
		return nil, "405 Method not allowed"
	end
end

-- Parse the HTTP headers.
-- Returns them as a table.
function readHeaders(c)
	local headers = {}
	local headerLine = c:receive('*l')
	while (headerLine) do
		local nextLine = c:receive('*l')
		if (not nextLine) then
			-- Error, should always be a blank line at least.	
			return nil
		end
		if (nextLine:match("^%s")) then
			headerLine = headerLine .. nextLine:gsub("%s+", " ", 1)
		else
			-- Header line does not start with space; previous header is complete.
			local name, value = headerLine:match("^([^:]+): ?(.*)$")
			-- log("header: " .. name)
			-- log("value: " .. value)
			headers[name:lower()] = value
			if (nextLine == "") then
				return headers
			end
			headerLine = nextLine
		end
	end
end

-- Fetch the HTTP body.
function readBody(c, len)
	local result = ""
	if (len) then
		-- log("Reading " .. len .. " bytes")
		local bytesToRead = len
		while (bytesToRead > 0) do
			local data, reason = c:receive(len)
			if (data) then
				bytesToRead = bytesToRead - data:len()
				result = result .. data
			else
				return nil, reason
			end
		end
	else
		-- Untested!
		log("Reading till EOF")
		while (true) do
			local data, reason = c:receive("*a")
			log(data)
			log(reason)
			if (data) then
				result = result .. data
			else
				return nil, reason
			end
		end
	end

	return result
end

-- Add a notification to the notification queue.
-- This queue will be sent when the proxy process
-- is back in its main loop.
function queueVariableNotification(sid, variable, value)
	log("Queueing notification for " .. sid .. "/" .. variable.name .. " = " .. value)
	table.insert(notificationQueue, {
		delayUntil = os.time(),
		retries = 3,
		url = "http://" .. variable.host .. ":3480/data_request?id=lu_action" ..
		"&DeviceNum=" .. url.escape(variable.deviceId) ..
		"&serviceId=" .. url.escape(variable.serviceId) ..
		"&action=" .. url.escape(variable.action) ..
		"&" .. url.escape(variable.parameter) .. "=" .. url.escape(value) ..
		(variable.sidParameter and ("&" .. url.escape(variable.sidParameter) .. "=" .. url.escape(sid)) or "")
	})
end

-- Ensure that a subscription is known about.
function createSubscription(sid, expiry, clearProxy)
	if (not subscriptions[sid]) then
		-- Unknown subscription.  Keep it around in case someone asks.
		if (not expiry) then
			-- 60 seconds ought to be enough.
			expiry = os.time() + 60
		end
		subscriptions[sid] = {
			variables = {},
			proxy = {},
			expiry = expiry,
		}
	elseif (expiry) then
		subscriptions[sid].expiry = expiry
	end
	if (clearProxy) then
		subscriptions[sid].proxy = {}
	end
end

-- Called when a UPnP device sends an event.
-- Store the value, and decide if a MiOS
-- plugin is interested in knowing about it.
function updateSubscribedVariable(sid, name, value)
	createSubscription(sid)
	subscriptions[sid].variables[name] = value
	log("Updated variable in subscription " .. sid .. ": " .. name .. " = " .. value)
	-- Proxy target may have already checked in.
	for _, v in pairs(subscriptions[sid].proxy) do
		if (name == v.name) then
			queueVariableNotification(sid, v, value)
		end
	end
end

-- Called when a MiOS plugin tells us that it
-- has requested a subscription.
-- Store the callback information, and decide if
-- the device has already reported a value for this
-- variable.
function addProxy(sid, variable)
	createSubscription(sid)
	table.insert(subscriptions[sid].proxy, variable)
	if (subscriptions[sid].variables[variable.name]) then
		-- Variable value is already known.  Queue up a notification.
		queueVariableNotification(sid, variable, subscriptions[sid].variables[variable.name])
	end
end

-- Returns a parser object that handles a UPnP NOTIFY body.
function createUpnpNotificationParser()
	local currentXpathTable = {}

	local currentXpath = function()
		return "/" .. table.concat(currentXpathTable, "/")
	end

	local result = {}
	local variableName = nil

	local xmlParser = lxp.new({
		CharacterData = function(parser, string)
			if (variableName) then
				result[variableName] = result[variableName] .. string
			end
	 	end,
		StartElement = function(parser, elementName, attributes)
			-- log("Start element: " .. elementName)
			table.insert(currentXpathTable, elementName)
			if (#currentXpathTable == 3 and currentXpathTable[1] == "urn:schemas-upnp-org:event-1-0|propertyset" and currentXpathTable[2] == "urn:schemas-upnp-org:event-1-0|property") then
				-- log("Variable: " .. elementName)
				variableName = elementName
				result[variableName] = ""
			end
		end,
		EndElement = function(parser, elementName)
			table.remove(currentXpathTable)
			variableName = nil
		end,
	}, "|")

	return {
		parse = function(this, s) return xmlParser:parse(s) end,
		close = function(this) xmlParser:close() end,
		result = function(this) return result end,
	}
end

-- Returns a parser object that handles PUT requests
-- made by a MiOS plugin wanting to be informed of events.
function createProxyRequestParser()
	local currentXpathTable = {}

	local currentXpath = function()
		return "/" .. table.concat(currentXpathTable, "/")
	end

	local variables = {}
	local expiry

	local xmlParser = lxp.new({
		StartElement = function(parser, elementName, attributes)
			-- log("Start element: " .. elementName)
			table.insert(currentXpathTable, elementName)
			if (#currentXpathTable == 1 and currentXpathTable[1] == "subscription") then
				expiry = attributes.expiry;
			elseif (#currentXpathTable == 2 and currentXpathTable[1] == "subscription" and currentXpathTable[2] == "variable") then
				local variable = {}
				variable.name = attributes.name
				variable.host = attributes.host
				variable.deviceId = attributes.deviceId
				variable.serviceId = attributes.serviceId
				variable.action = attributes.action
				variable.parameter = attributes.parameter
				variable.sidParameter = attributes.sidParameter
				table.insert(variables, variable)
			end
		end,
		EndElement = function(parser, elementName)
			table.remove(currentXpathTable)
		end,
	}, "|")

	return {
		parse = function(this, s) return xmlParser:parse(s) end,
		close = function(this) xmlParser:close() end,
		expiry = function(this) return expiry end,
		variables = function(this) return variables end,
	}
end

-- Handle all PUT requests:
--   MiOS plugin is telling us of a subscription that it made.
function handlePutRequest(c, path, headers, body)
	if (#path == 3 and path[1] == "upnp" and path[2] == "event") then
		-- Plugin is asking to be sent notifications for this subscription.
		local sid = path[3]
		local proxyRequestParser = createProxyRequestParser()
		local result, reason = proxyRequestParser:parse(body)
		proxyRequestParser:close()
		if (result) then
			local variables = proxyRequestParser:variables()
			local expiry = proxyRequestParser:expiry()
			createSubscription(sid, tonumber(expiry), true)
			for i = 1, #variables do
				log ("Will forward events for " .. variables[i].name)
				addProxy(sid, variables[i])
			end
			c:send("HTTP/1.1 200 OK\r\n\r\n")
		else
			log("Parser failed: " .. reason)
			c:send("HTTP/1.1 412 Precondition Failed\r\n\r\n")
		end
	else
		c:send("HTTP/1.1 403 Forbidden\r\n\r\n")
	end
	return true
end

-- Handle all GET requests:
--   API version of this web server.
function handleGetRequest(c, path, headers)
	if (#path == 1 and path[1] == "version") then
		-- GET /version
		-- Returns the API version.
		c:send("HTTP/1.1 200 OK\r\n" .. "Content-Length: " .. API_VERSION:len() .. "\r\nContent-Type: text/plain\r\n\r\n" .. API_VERSION)
	else
	  c:send("HTTP/1.1 404 Not found\r\n\r\n")
	end
	return true
end

-- Handle all DELETE requests:
--   MiOS plugin doesn't want to be informed about a subscription.
function handleDeleteRequest(c, path, headers)
	if (#path == 3 and path[1] == "upnp" and path[2] == "event") then
		-- Plugin is asking to no longer be sent notifications for this subscription.
		local sid = path[3]
		subscriptions[sid] = nil
		c:send("HTTP/1.1 200 OK\r\n\r\n")
	else
		c:send("HTTP/1.1 404 Not Found\r\n\r\n")
	end
	return true
end

-- Handle all NOTIFY requests:
--   UPnP device is sending an event that a MiOS plugin subscribed to.
function handleNotifyRequest(c, path, headers, body)
	if (#path == 2 and path[1] == "upnp" and path[2] == "event") then
		-- NOTIFY /upnp/event
		-- UPnP device is informing of a state change.
		-- UPnP spec deviation: WeMo devices insert NUL bytes in the XML.
		body = body:gsub("%z", " ")
		local upnpParser = createUpnpNotificationParser()
		local result, reason = upnpParser:parse(body)
		upnpParser:close()
		if (result) then
			-- log("Parser succeeded")
			for k, v in pairs(upnpParser.result()) do
				updateSubscribedVariable(headers["sid"], k, v)
			end
			c:send("HTTP/1.1 200 OK\r\n\r\n")
		else
			log("Parser failed: " .. reason)
			c:send("HTTP/1.1 412 Precondition Failed\r\n\r\n")
		end
	else
		c:send("HTTP/1.1 404 Not Found\r\n\r\n")
	end
	return true
end

-- Handle an incoming HTTP request.
function handleRequest(c, method, path, headers, body)
	if (method == "PUT") then
		return handlePutRequest(c, path, headers, body)
	elseif (method == "GET") then
		return handleGetRequest(c, path, headers)
	elseif (method == "DELETE") then
		return handleDeleteRequest(c, path, headers)
	elseif (method == "NOTIFY") then
		return handleNotifyRequest(c, path, headers, body)
	else
		c:send("405 Method Not Allowed\r\n\r\n")
		return true
	end
end

-- Send outstanding notifications to MiOS plugins.
function processNotificationQueue()
	local saveForLater = {}
	local nextTimeout = LISTEN_TIMEOUT
	while (#notificationQueue > 0) do
		local notification = table.remove(notificationQueue, 1)
		if (notification.delayUntil > os.time()) then
			-- Don't send yet, device may not be ready.
			log("Event not ready, try again later")
			table.insert(saveForLater, notification)
		else
			log("Sending notification: " .. notification.url)
			local request, reason = http.request(notification.url)
			-- Oh god, string matching.  "Device Not Ready" still comes with a 200 OK.
			if (request and not(request:match("ERROR: Device not ready"))) then
				-- Successful notification.
				-- log("Response: " .. request)
			else
				log("Error: " .. reason)
				if (notification.retries > 0) then
					local randomDelay = math.random(1, 5)
					notification.delayUntil = os.time() + randomDelay
					notification.retries = notification.retries - 1
					nextTimeout = math.min(nextTimeout, randomDelay)
					table.insert(saveForLater, notification)
				end
			end
			-- Wait at most ten seconds, at least 1.
			nextTimeout = math.min(nextTimeout, LISTEN_TIMEOUT)
			nextTimeout = math.max(nextTimeout, 1)
		end
	end
	-- Unsuccessful notifications will be requeued for next time.
	for _, notification in pairs(saveForLater) do
		table.insert(notificationQueue, notification)
	end
	return nextTimeout
end

-- Eliminate old subscriptions to prevent memory leaks.
function purgeExpiredSubscriptions()
	for sid, info in pairs(subscriptions) do
		if (info.expiry < os.time()) then
			subscriptions[sid] = nil
		end
	end
end

-- Run until instructed to exit (not yet implemented)
local runServer = true

local s = socket.tcp()
s:setoption("reuseaddr", true)
-- Every LISTEN_TIMEOUT seconds deal with retried notifications.
s:settimeout(LISTEN_TIMEOUT)
local result, reason = s:bind('*', LISTEN_PORT)
if (not result) then
	log("Cannot bind to port: " .. reason)
	os.exit(1)
end
result, reason = s:listen(LISTEN_BACKLOG)
if (not result) then
	log("Cannot listen: " .. reason)
	os.exit(1)
end

repeat
	-- Wait (until timeout, perhaps) for a connection.
	local c = s:accept()
	if (c) then
		local remoteHost = c:getpeername()
		-- log("Connection established from " .. remoteHost)

		local method, path = readStatusLine(c)
		if (method) then
			local logstring = os.date() .. " " .. remoteHost .. " > " .. method .. " "
			for i = 1, #path do
				logstring = logstring .. "/" .. path[i]
			end
			log(logstring)
			-- So far so good.
			local headers = readHeaders(c)
			if (headers) then
				-- Now read body.
				local body
				if (method == "GET" or method == "DELETE") then
					body = nil
				elseif (headers["content-length"]) then
					body = readBody(c, tonumber(headers["content-length"]))
				else
					body = readBody(c, nil)
				end
				-- Dispatch the request.
				runServer = handleRequest(c, method, path, headers, body)
			else
				log("Error while processing headers")
				c:send("HTTP/1.1 400 Bad Request\r\n\r\n")
			end
		else
			-- path contains the error code.
			log("Error while processing request line: " .. path)
			c:send("HTTP/1.1 500 " .. path .. "\r\n\r\n")
		end
		c:close()

	end

	-- Send outstanding notifications.
	s:settimeout(processNotificationQueue())

  purgeExpiredSubscriptions()

until not runServer

s:close()

