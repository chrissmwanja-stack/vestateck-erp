import { describe, expect, it } from 'vitest';
import { functionErrorMessage } from './functionError';

const withBody = (body: string, message = 'Edge Function returned a non-2xx status code') => ({
  message,
  context: new Response(body, { status: 409 }),
});

describe('functionErrorMessage', () => {
  it('returns the { error } string from the response body', async () => {
    expect(await functionErrorMessage(withBody(JSON.stringify({ error: 'Email already registered' })))).toBe(
      'Email already registered',
    );
  });

  it('falls back to the error message when the body is not JSON', async () => {
    expect(await functionErrorMessage(withBody('<html>Bad gateway</html>'))).toBe(
      'Edge Function returned a non-2xx status code',
    );
  });

  it('falls back to the error message when the body has no usable error field', async () => {
    expect(await functionErrorMessage(withBody(JSON.stringify({ ok: false })))).toBe(
      'Edge Function returned a non-2xx status code',
    );
  });

  it('handles a plain Error with no response context', async () => {
    expect(await functionErrorMessage(new Error('network down'))).toBe('network down');
  });

  it('handles null/undefined', async () => {
    expect(await functionErrorMessage(undefined)).toBe('Request failed');
  });
});
