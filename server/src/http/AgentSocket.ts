import { Effect } from "effect"
import { HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/http"
import { LineHub } from "../services/LineHub.ts"

// Mac agents dial out to this endpoint; see protocol/README.md.
export const AgentSocketRoute = HttpRouter.add(
  "GET",
  "/v1/agent/connect",
  Effect.gen(function*() {
    const request = yield* HttpServerRequest.HttpServerRequest
    const hub = yield* LineHub
    const token = request.headers["authorization"]?.replace(/^Bearer /, "")
    const lineId = token ? yield* hub.authenticate(token) : undefined
    if (!lineId) return HttpServerResponse.text("unauthorized", { status: 401 })
    const socket = yield* request.upgrade
    yield* hub.connect(lineId, socket)
    return HttpServerResponse.empty()
  })
)
