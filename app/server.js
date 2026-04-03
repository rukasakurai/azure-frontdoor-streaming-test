'use strict'

const fastify = require('fastify')({ logger: true })
const https = require('https')
const { URL } = require('url')

const PORT = process.env.PORT || 3000
const EVENT_COUNT = 10
const INTERVAL_MS = 1000

// Microsoft Foundry configuration (set via App Service app settings)
const FOUNDRY_ENDPOINT = process.env.FOUNDRY_ENDPOINT || ''
const FOUNDRY_API_KEY = process.env.FOUNDRY_API_KEY || ''
const FOUNDRY_DEPLOYMENT_NAME = process.env.FOUNDRY_DEPLOYMENT_NAME || 'gpt-4o-mini'

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

// SSE Agent endpoint – proxies a streaming chat completion from Microsoft Foundry
fastify.get('/sse-agent', (request, reply) => {
  if (!FOUNDRY_ENDPOINT || !FOUNDRY_API_KEY) {
    reply.code(503).send({
      error: 'Microsoft Foundry is not configured',
      detail: 'Set FOUNDRY_ENDPOINT and FOUNDRY_API_KEY environment variables',
    })
    return
  }

  // Build the Azure OpenAI streaming chat completions URL
  const baseUrl = FOUNDRY_ENDPOINT.replace(/\/$/, '')
  const chatUrl = `${baseUrl}/openai/deployments/${encodeURIComponent(FOUNDRY_DEPLOYMENT_NAME)}/chat/completions?api-version=2024-10-21`
  const parsed = new URL(chatUrl)

  const body = JSON.stringify({
    messages: [
      {
        role: 'system',
        content: 'You are a helpful assistant. Respond with a numbered list of exactly 10 interesting facts about space exploration. Write each fact on its own line.',
      },
      {
        role: 'user',
        content: 'Tell me 10 facts about space exploration.',
      },
    ],
    stream: true,
    max_tokens: 512,
  })

  const options = {
    hostname: parsed.hostname,
    port: 443,
    path: parsed.pathname + parsed.search,
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'api-key': FOUNDRY_API_KEY,
      'Content-Length': Buffer.byteLength(body),
    },
  }

  // Set SSE response headers before proxying
  reply.raw.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'X-Accel-Buffering': 'no',
    Connection: 'keep-alive',
  })

  const proxyReq = https.request(options, (proxyRes) => {
    if (proxyRes.statusCode !== 200) {
      let errBody = ''
      proxyRes.on('data', (chunk) => { errBody += chunk })
      proxyRes.on('end', () => {
        fastify.log.error({ statusCode: proxyRes.statusCode, body: errBody }, 'Foundry API error')
        reply.raw.write(`data: ${JSON.stringify({ error: 'Foundry API error', statusCode: proxyRes.statusCode })}\n\n`)
        reply.raw.end()
      })
      return
    }

    // Proxy the SSE stream directly from Foundry to the client
    proxyRes.on('data', (chunk) => {
      reply.raw.write(chunk)
    })

    proxyRes.on('end', () => {
      reply.raw.end()
    })
  })

  proxyReq.on('error', (err) => {
    fastify.log.error({ err }, 'Foundry proxy request error')
    reply.raw.write(`data: ${JSON.stringify({ error: 'Proxy request failed', message: err.message })}\n\n`)
    reply.raw.end()
  })

  request.raw.on('close', () => {
    proxyReq.destroy()
  })

  proxyReq.write(body)
  proxyReq.end()
})

fastify.listen({ port: PORT, host: '0.0.0.0' }, (err) => {
  if (err) {
    fastify.log.error(err)
    process.exit(1)
  }
})
