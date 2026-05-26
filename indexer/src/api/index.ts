import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { client, graphql } from "ponder";

const app = new Hono();

// Ponder built-in SQL client + GraphQL
app.use("/sql/*", client({ db, schema }));
app.use("/", graphql({ db, schema }));
app.use("/graphql", graphql({ db, schema }));

/**
 * The SGSMM agent consumes data via Ponder's GraphQL endpoint at /graphql.
 *
 * Custom REST endpoints (eligible-wallets, wallet/:address, health) deferred
 * to a later iteration where we'll either:
 *   1) Use Ponder's hono integration to expose typed SQL queries, or
 *   2) Add a thin FastAPI-side gateway to translate GraphQL into agent-shaped JSON.
 *
 * For the hackathon scope, the agent talks GraphQL directly — sufficient.
 */

export default app;
