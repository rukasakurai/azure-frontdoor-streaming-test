'use strict'

const fastify = require('fastify')({ logger: true })
const fs = require('fs')
const http = require('http')
const https = require('https')
const path = require('path')
const { URL } = require('url')

const PORT = process.env.PORT || 3000
const EVENT_COUNT = 10
const INTERVAL_MS = 1000
const STATIC_ROOT = path.join(__dirname, 'public', 'static-test')

const staticAssets = {
  'index.html': 'text/html; charset=utf-8',
  'app.js': 'application/javascript; charset=utf-8',
  'style.css': 'text/css; charset=utf-8',
  'data.csv': 'text/csv; charset=utf-8',
  'large.txt': 'text/plain; charset=utf-8',
}

const staticScenarios = {
  cacheable: {
    cacheControl: 'public, max-age=300',
    assets: new Set(Object.keys(staticAssets)),
  },
  'no-store': {
    cacheControl: 'no-store',
    assets: new Set(Object.keys(staticAssets)),
  },
  query: {
    cacheControl: 'public, max-age=300',
    assets: new Set(Object.keys(staticAssets)),
  },
  large: {
    cacheControl: 'public, max-age=300',
    assets: new Set(['large.txt']),
  },
}

// Microsoft Foundry configuration (set via App Service app settings)
const FOUNDRY_ENDPOINT = process.env.FOUNDRY_ENDPOINT || ''
const FOUNDRY_DEPLOYMENT_NAME = process.env.FOUNDRY_DEPLOYMENT_NAME || 'gpt-4o-mini'
const COGNITIVE_SERVICES_RESOURCE = 'https://cognitiveservices.azure.com/'
let foundryToken = { accessToken: '', expiresAtMs: 0 }

// Health probe endpoint used by Azure Front Door
fastify.get('/health', async (request, reply) => {
  return { status: 'ok' }
})

function sendStaticAsset(reply, asset, cacheControl) {
  const contentType = staticAssets[asset]
  if (!contentType) {
    reply.code(404).send({ error: 'Static test asset not found' })
    return
  }

  const filePath = path.join(STATIC_ROOT, asset)
  reply
    .header('Cache-Control', cacheControl)
    .header('Content-Type', contentType)
    .send(fs.createReadStream(filePath))
}

fastify.get('/static-test/:scenario/:asset', (request, reply) => {
  const scenario = staticScenarios[request.params.scenario]
  if (!scenario || !scenario.assets.has(request.params.asset)) {
    reply.code(404).send({ error: 'Static test scenario asset not found' })
    return
  }

  sendStaticAsset(reply, request.params.asset, scenario.cacheControl)
})

fastify.get('/static-test/:asset', (request, reply) => {
  sendStaticAsset(reply, request.params.asset, 'public, max-age=300')
})

fastify.get('/cache-baseline/static-test/:scenario/:asset', (request, reply) => {
  const scenario = staticScenarios[request.params.scenario]
  if (!scenario || !scenario.assets.has(request.params.asset)) {
    reply.code(404).send({ error: 'Static test scenario asset not found' })
    return
  }

  sendStaticAsset(reply, request.params.asset, scenario.cacheControl)
})

function parseTokenExpiry(expiresOn) {
  if (!expiresOn) {
    return Date.now() + 50 * 60 * 1000
  }

  if (/^\d+$/.test(String(expiresOn))) {
    const value = Number(expiresOn)
    return value > 1e12 ? value : value * 1000
  }

  const parsed = Date.parse(expiresOn)
  return Number.isNaN(parsed) ? Date.now() + 50 * 60 * 1000 : parsed
}

function requestManagedIdentityToken(resource) {
  return new Promise((resolve, reject) => {
    if (!process.env.IDENTITY_ENDPOINT || !process.env.IDENTITY_HEADER) {
      reject(new Error('Managed identity endpoint is not available'))
      return
    }

    const tokenUrl = new URL(process.env.IDENTITY_ENDPOINT)
    tokenUrl.searchParams.set('api-version', '2019-08-01')
    tokenUrl.searchParams.set('resource', resource)

    const client = tokenUrl.protocol === 'https:' ? https : http
    const req = client.request({
      hostname: tokenUrl.hostname,
      port: tokenUrl.port || (tokenUrl.protocol === 'https:' ? 443 : 80),
      path: `${tokenUrl.pathname}${tokenUrl.search}`,
      method: 'GET',
      headers: {
        'X-IDENTITY-HEADER': process.env.IDENTITY_HEADER,
      },
    }, (res) => {
      const chunks = []
      res.on('data', (chunk) => { chunks.push(chunk) })
      res.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8')
        if (res.statusCode !== 200) {
          reject(new Error(`Managed identity token request failed with HTTP ${res.statusCode}: ${body}`))
          return
        }

        try {
          const token = JSON.parse(body)
          if (!token.access_token) {
            reject(new Error('Managed identity token response did not include access_token'))
            return
          }
          resolve({
            accessToken: token.access_token,
            expiresAtMs: parseTokenExpiry(token.expires_on),
          })
        } catch (err) {
          reject(err)
        }
      })
    })

    req.on('error', reject)
    req.end()
  })
}

async function getFoundryAccessToken() {
  if (foundryToken.accessToken && foundryToken.expiresAtMs - Date.now() > 5 * 60 * 1000) {
    return foundryToken.accessToken
  }

  foundryToken = await requestManagedIdentityToken(COGNITIVE_SERVICES_RESOURCE)
  return foundryToken.accessToken
}

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
  if (!FOUNDRY_ENDPOINT) {
    reply.code(503).send({
      error: 'Microsoft Foundry is not configured',
      detail: 'Set FOUNDRY_ENDPOINT and enable managed identity authentication',
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

  getFoundryAccessToken().then((accessToken) => {
    const options = {
      hostname: parsed.hostname,
      port: 443,
      path: parsed.pathname + parsed.search,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${accessToken}`,
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
        const errChunks = []
        proxyRes.on('data', (chunk) => { errChunks.push(chunk) })
        proxyRes.on('end', () => {
          const errBody = Buffer.concat(errChunks).toString('utf8')
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
  }).catch((err) => {
    fastify.log.error({ err }, 'Foundry proxy request error')
    reply.code(503).send({
      error: 'Microsoft Foundry authentication failed',
      detail: err.message,
    })
  })
})

fastify.listen({ port: PORT, host: '0.0.0.0' }, (err) => {
  if (err) {
    fastify.log.error(err)
    process.exit(1)
  }
})
