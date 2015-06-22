# MiOS-UPnPEventProxy

This plugin runs a simple HTTP server on your Vera which listens for UPnP NOTIFY messages, and forwards them on to another MiOS plugin.
End user documentation

If you have been sent here by a different plugin, it's because that plugin wants you to install the UPnP Event Proxy plugin. If you don't install the UPnP Event Proxy then you may find that the other plugin runs with reduced functionality, most likely that changes made outside the plugin aren't immediately visible in the MiOS dashboard.

## Installation

The simplest way to install this plugin is from ​apps.mios.com. The plugin needs one extra Luup engine reload, which it prompts you to do.

The plugin adds one device to the dashboard. This device is normally not needed, except for debugging purposes and to uninstall the plugin.

## Uninstallation

If you need to uninstall the proxy, open up its control panel to the first tab and press Uninstall. Then delete the device and press SAVE.

If you forget to do this then the proxy will continue to run on your Vera, even after a reboot. This is probably harmless but it is consuming resources. To manually stop the proxy after you have uninstalled the plugin, follow these steps:

1. Go to Apps > Develop Apps > Test Luup Code.
2. Paste the following into the text area and press GO:

```
os.execute("/etc/init.d/upnp-event-proxy stop")
os.execute("/etc/init.d/upnp-event-proxy disable")
os.execute("rm /etc/init.d/upnp-event-proxy")
```

# Developer documentation

 The UPnP Event Proxy is a daemon which works around a ​known bug in the MiOS web server implementation (namely, that it does not accept NOTIFY HTTP messages).

The proxy runs a simple Lua web server at Vera startup, which listens for a small set of HTTP commands, which are either NOTIFY messages, or requests from Vera plugins to be informed when a NOTIFY message is received. When the proxy receives a NOTIFY message, it sends a Luup ​action message to the plugin so that it can act upon the notification.

## Typical use case

NOTIFY is one of the message types defined in the UPnP standard, and is used when a UPnP device needs to tell a UPnP control point about a state variable that has changed. For example, a UPnP device such as a WeMo? motion sensor may have detected motion, or a UPnP media device such as a Sonos may have had its volume level changed by the user.

MiOS plugins that interact with UPnP devices may wish to be informed of these events, so that they can modify the dashboard UI to match, or so that they can fire a scene trigger.

The UPnP mechanism that the plugin uses is to send a UPnP SUBSCRIBE message to the UPnP device. Inside this SUBSCRIBE message is the URL that the device should try to contact whenever the event occurs. The UPnP device will immediately return a unique string, a subscription identifier (SID). Any time that the event occurs, the UPnP device will send a NOTIFY message to the callback URL, quoting this SID, so that the receiver knows which device has had the event.

The MiOS LuaUPnP process cannot receive NOTIFY messages, so the plugin instead nominates the UPnP Event Proxy daemon as the callback URL. The plugin must also inform the UPnP Event Proxy daemon of the SID, and which Luup action on the plugin to invoke when the event occurs.

## Setup code

The example code below assumes these variables:

```
http = require("socket.http")
ltn12 = require("ltn12")
function socketWithTimeout(timeout)
  local s = socket.tcp()
  s:settimeout(timeout)
  return s
end
```

## Checking that the proxy is running

Your plugin should check that the proxy is running, by querying its API version string.

```
local ProxyApiVersion
local t = {}
local request, code = http.request({
  url = "http://localhost:2529/version",
  create = socketWithTimeout(2),
  sink = ltn12.sink.table(t)
})

if (request == nil and code == "timeout") then
  -- Proxy may be busy (retry).
elseif (request == nil and code ~= "closed") then
  -- Proxy not running.
else
  -- Proxy is running, note its version number.
  ProxyApiVersion = table.concat(t)
end
```

## Registering a subscription with the proxy

In this example, the plugin at MiOS deviceId deviceId is interested in knowing about changes to the UPnP variable UPnPVariable.

Sending the UPnP SUBSCRIBE request is outside the scope of this document. For example code, see the Belkin WeMo? plugin function ​subscribeToDevice(). The callback URL must be <​http://''vera-address'':2529/upnp/event>.

After the SUBSCRIBE request succeeds, the plugin will have a subscription identifier (SID) sid, and a duration in seconds timeout. For the next timeout seconds, the UPnP device will send NOTIFY messages to the callback URL.

The plugin has an action VariableChanged in service pluginServiceId which accepts two parameters: valueParam (the new value of the varable), and sidParam (the subscription identifier). The plugin wants this action to be invoked by the proxy every time that UPnPVariable changes.

To register the subscription with the proxy, perform an HTTP PUT to /upnp/event/sid:

```
local proxyRequestBody = "<subscription expiry='" .. os.time() + timeout .. "'>"
proxyRequestBody = proxyRequestBody ..
  "<variable name='UPnPVariable' host='localhost' deviceId='" ..
  deviceId .. "' serviceId='pluginServiceId' " ..
  "action='VariableChanged' parameter='valueParam' sidParameter='sidParam'/>"
proxyRequestBody = proxyRequestBody .. "</subscription>"
local request, code = http.request({
  url = "http://localhost:2529/upnp/event/" .. url.escape(sid),
  create = socketWithTimeout(2),
  method = "PUT",
  headers = {
    ["Content-Type"] = "text/xml",
    ["Content-Length"] = proxyRequestBody:len(),
  },
  source = ltn12.source.string(proxyRequestBody),
  sink = ltn12.sink.null(),
})
if (request == nil and code ~= "closed") then
  -- Failed (timeout?)
elseif (code ~= 200) then
  -- Failed (refused)
else
  -- Succeeded
end
```

The proxy will soon receive (or may have already received) the initial UPnP NOTIFY (with sequence 0), and will invoke the VariableChanged action on the plugin.

## Receiving an event notification from the proxy

The plugin should have an action VariableChanged, matching the serviceId and action parameters supplied in the previous section's sample code. In the

```
<action>
  <serviceId>pluginServiceId</serviceId>
  <name>VariableChanged</name>
  <run>
    doSomethingWith(lul_device, lul_settings.valueParam, lul_settings.sidParam)
  </run>
</action>
```

The doSomethingWith function will be called with the value of UPnPVariable from each notification from the UPnP device, and the SID mentioned in the event. Normally this function will set a Luup variable to reflect the reported change in the variable.

## Renewing the subscription

Before timeout seconds have passed, the plugin must renew the subscription with the UPnP device. The code to do this is outside the scope of this document.

If the renewal succeeds, a new timeout will be supplied by the UPnP device. The plugin must inform the proxy of the new expiry, using code exactly the same as the initial registration. This PUT request completely replaces the previous registration, so it must mention all variables again.

## Cancelling the subscription

In most cases, the plugin will want to keep renewing the subscription indefinitely. If the plugin knows that a subscription should be cancelled, it can ask the proxy to stop forwarding the event to the plugin with an HTTP DELETE:

```
local request, code = http.request({
  url = "http://localhost:2529/upnp/event/" .. url.escape(sid),
  create = socketWithTimeout(2),
  method = "DELETE",
  source = ltn12.source.empty(),
  sink = ltn12.sink.null(),
})
if (request == nil and code ~= "closed") then
  -- Failed (timeout?)
elseif (code ~= 200) then
  -- Failed (refused)
else
  -- Succeeded
end
```

If the Luup engine is restarted, the plugin will not have an opportunity to cancel a subscription, and the proxy will send events that were registered before the Luup engine was restarted. The plugin can use the sidParam value to see if this has happened. Eventually the subscription will expire and the plugin will stop receive notifications.

## Avoiding deadlocks

The proxy runs in a single thread. Consequently it is vital that plugins do not delay it when actions are invoked by the proxy, because it will prevent other plugins and UPnP devices from contacting the proxy.

To minimize the likelihood of delays, plugins should restrict their actions to a minimum during actions such as VariableChanged. The plugin should liberally use luup.call_delay() for anything that may block or take significant time to run.

Because the plugin makes HTTP requests to the proxy and the proxy makes action calls to the plugin, there is a risk of deadlock. To minimize this, the proxy will time out and retry after a random period of time from 1 to 5 seconds, up to a maximum of three times. If the action still cannot be delivered then it is discarded. It is a good idea for the plugin to do the same, using retry counters and luup.call_delay() to compartmentalize each invocation and allow the proxy to contact the plugin as soon as possible. 
