import { BunHttpServer, BunRuntime } from "@effect/platform-bun"
import { Config, Effect, Layer } from "effect"
import { HttpRouter } from "effect/http"
import { HttpApiBuilder, HttpApiScalar } from "effect/http-api"
import { Api } from "./api/Api.ts"
import { AgentSocketRoute } from "./http/AgentSocket.ts"
import { AuthorizationLive } from "./http/Authorization.ts"
import { HandlersLive } from "./http/Handlers.ts"
import { LineHub } from "./services/LineHub.ts"
import { SqlLive } from "./services/Sql.ts"
import { Webhooks } from "./services/Webhooks.ts"

const ServicesLive = Webhooks.layer.pipe(
  Layer.provideMerge(LineHub.layer),
  Layer.provideMerge(SqlLive)
)

const ApiRoutes = HttpApiBuilder.layer(Api, { openapiPath: "/openapi.json" }).pipe(
  Layer.provide(HandlersLive)
)

const AllRoutes = Layer.mergeAll(ApiRoutes, AgentSocketRoute, HttpApiScalar.layer(Api, { path: "/docs" }))

const ServerLive = Layer.unwrap(
  Effect.gen(function*() {
    const port = yield* Config.Number("PORT").pipe(Config.withDefault(8787))
    const hostname = yield* Config.String("HOST").pipe(Config.withDefault("0.0.0.0"))
    return BunHttpServer.layer({ port, hostname })
  })
)

HttpRouter.serve(AllRoutes).pipe(
  Layer.provide(AuthorizationLive),
  Layer.provide(ServicesLive),
  Layer.provide(ServerLive),
  Layer.launch,
  BunRuntime.runMain
)
