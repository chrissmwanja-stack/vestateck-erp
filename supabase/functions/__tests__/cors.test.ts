import { describe, expect, it } from 'vitest';
import { loadCors, req } from './harness';

describe('buildCorsHeaders', () => {
  it('echoes an allowlisted origin and marks the response as varying by Origin', async () => {
    const { buildCorsHeaders } = await loadCors('https://app.example.com, https://staging.example.com');
    const h = buildCorsHeaders(req({}, { origin: 'https://staging.example.com' }));
    expect(h['Access-Control-Allow-Origin']).toBe('https://staging.example.com');
    expect(h.Vary).toBe('Origin');
  });

  it('omits Allow-Origin for an origin that is not on the list', async () => {
    const { buildCorsHeaders } = await loadCors('https://app.example.com');
    const h = buildCorsHeaders(req({}, { origin: 'https://evil.example' }));
    expect(h['Access-Control-Allow-Origin']).toBeUndefined();
    expect(h.Vary).toBe('Origin');
  });

  it('never answers with a wildcard, and omits the header when there is no Origin', async () => {
    const { buildCorsHeaders } = await loadCors('https://app.example.com');
    expect(buildCorsHeaders(req({})) ['Access-Control-Allow-Origin']).toBeUndefined();
  });

  it('matches origins exactly (no prefix or subdomain tricks)', async () => {
    const { buildCorsHeaders } = await loadCors('https://app.example.com');
    for (const origin of ['https://app.example.com.evil.io', 'http://app.example.com', 'https://app.example.com/']) {
      expect(buildCorsHeaders(req({}, { origin }))['Access-Control-Allow-Origin']).toBeUndefined();
    }
  });

  it('defaults to the Vite dev origin only when ALLOWED_ORIGINS is unset', async () => {
    const { buildCorsHeaders } = await loadCors(undefined);
    expect(buildCorsHeaders(req({}, { origin: 'http://localhost:5173' }))['Access-Control-Allow-Origin']).toBe(
      'http://localhost:5173',
    );
    expect(buildCorsHeaders(req({}, { origin: 'https://app.example.com' }))['Access-Control-Allow-Origin']).toBeUndefined();
  });

  it('ignores blank entries in the list', async () => {
    const { buildCorsHeaders } = await loadCors(' , https://app.example.com ,');
    expect(buildCorsHeaders(req({}, { origin: '' }))['Access-Control-Allow-Origin']).toBeUndefined();
    expect(buildCorsHeaders(req({}, { origin: 'https://app.example.com' }))['Access-Control-Allow-Origin']).toBe(
      'https://app.example.com',
    );
  });
});
