// Simulates a Mac agent for local development: answers commands and emits a message event.
const url = process.env.BLUEBERRY_URL ?? "ws://localhost:8787/v1/agent/connect"
const token = process.env.LINE_TOKEN!
const ws = new WebSocket(url, { headers: { authorization: `Bearer ${token}` } } as any)
let seq = 0
ws.onopen = () =>
  ws.send(JSON.stringify({ type: "hello", protocol: 1, agentVersion: "fake", macOS: "26.6.2", capabilities: ["send.applescript"], accounts: [{ service: "iMessage", handle: "+15550001111" }] }))
ws.onmessage = (e) => {
  const f = JSON.parse(String(e.data))
  console.log("<-", JSON.stringify(f))
  if (f.type === "ping") ws.send(JSON.stringify({ type: "pong", t: f.t }))
  if (f.type === "welcome") {
    ws.send(JSON.stringify({ type: "event", seq: ++seq, event: { kind: "message.new", message: {
      rowId: f.resumeAfterRowId + 1, guid: `fake-${Date.now()}`, chatGuid: "iMessage;-;+15552223333", sender: "+15552223333", isFromMe: false,
      service: "iMessage", text: "hey from the fake mac", subject: null, replyToGuid: null, threadOriginatorGuid: null, associatedMessageGuid: null,
      associatedMessageType: 0, expressiveSendStyleId: null, dateSent: new Date().toISOString(), dateDelivered: null, dateRead: null,
      dateEdited: null, dateRetracted: null, error: 0, attachments: [] } } }))
  }
  if (f.type === "command") ws.send(JSON.stringify({ type: "result", id: f.id, ok: true, data: { guid: `sent-${f.id}`, echo: f.command } }))
}
ws.onclose = (e) => console.log("closed", e.code, e.reason)
