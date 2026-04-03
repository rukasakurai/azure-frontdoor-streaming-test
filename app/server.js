'use strict'

const fastify = require('fastify')({ logger: true })

const PORT = process.env.PORT || 3000
const EVENT_COUNT = 10
const INTERVAL_MS = 1000

// Health probe endpoint used by Azure Front Door
fastify.get('/health', async (request, reply) => {
  return { status: 'ok' }
})

// SSE endpoint – sends 10 events at 1-second intervals
fastify.get('/sse', (request, reply) => {
  reply.raw.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'X-Accel-Buffering': 'no',
    Connection: 'keep-alive',
  })

  let count = 0
  const interval = setInterval(() => {
    count++
    const ts = new Date().toISOString()
    reply.raw.write(`data: ${JSON.stringify({ index: count, time: ts })}\n\n`)
    if (count >= EVENT_COUNT) {
      clearInterval(interval)
      reply.raw.end()
    }
  }, INTERVAL_MS)

  request.raw.on('close', () => clearInterval(interval))
})

// NDJSON endpoint – sends 10 JSON lines at 1-second intervals
fastify.get('/ndjson', (request, reply) => {
  reply.raw.writeHead(200, {
    'Content-Type': 'application/x-ndjson',
    'Cache-Control': 'no-cache',
    'Transfer-Encoding': 'chunked',
  })

  let count = 0
  const interval = setInterval(() => {
    count++
    const ts = new Date().toISOString()
    reply.raw.write(JSON.stringify({ index: count, time: ts }) + '\n')
    if (count >= EVENT_COUNT) {
      clearInterval(interval)
      reply.raw.end()
    }
  }, INTERVAL_MS)

  request.raw.on('close', () => clearInterval(interval))
})

fastify.listen({ port: PORT, host: '0.0.0.0' }, (err) => {
  if (err) {
    fastify.log.error(err)
    process.exit(1)
  }
})
