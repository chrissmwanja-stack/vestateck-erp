import { afterEach, describe, expect, it, vi } from 'vitest';
import { DEFAULT_BRANDING, escapeHtml, loadBranding, renderEmail, sendEmail, type Branding } from '../_shared/branding';

const B: Branding = { platformName: 'Acme ERP', logoUrl: '', primaryColor: '#112233', supportEmail: '', tagline: 't' };

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('escapeHtml', () => {
  it('escapes the five HTML-significant characters', () => {
    expect(escapeHtml(`<a href="x" onclick='y'>&</a>`)).toBe('&lt;a href=&quot;x&quot; onclick=&#39;y&#39;&gt;&amp;&lt;/a&gt;');
  });
  it('escapes ampersands first (no double-escaping of its own output)', () => {
    expect(escapeHtml('&lt;')).toBe('&amp;lt;');
  });
  it('renders null and undefined as empty, and coerces other types', () => {
    expect(escapeHtml(null)).toBe('');
    expect(escapeHtml(undefined)).toBe('');
    expect(escapeHtml(42)).toBe('42');
  });
});

describe('loadBranding', () => {
  const client = (result: unknown) => ({ rpc: () => ({ single: () => Promise.resolve(result) }) });

  it('maps the RPC row to branding', async () => {
    const b = await loadBranding(
      client({
        data: {
          platform_name: 'Acme ERP',
          logo_url: 'https://cdn.example.com/logo.png',
          primary_color: '#AABBCC',
          support_email: 'help@acme.example',
          tagline: 'Build better',
        },
        error: null,
      }),
    );
    expect(b).toEqual({
      platformName: 'Acme ERP',
      logoUrl: 'https://cdn.example.com/logo.png',
      primaryColor: '#AABBCC',
      supportEmail: 'help@acme.example',
      tagline: 'Build better',
    });
  });

  it.each([
    ['javascript: URL', 'javascript:alert(1)'],
    ['data: URL', 'data:image/svg+xml;base64,AAAA'],
    ['protocol-relative URL', '//evil.example/x.png'],
    ['javascript: URL that merely mentions an https URL', 'javascript:alert("https://ok.example")'],
    ['non-http scheme wrapping an https URL', 'ftp://host/https://ok.example/logo.png'],
  ])('drops a %s logo', async (_l, logo_url) => {
    const b = await loadBranding(client({ data: { logo_url }, error: null }));
    expect(b.logoUrl).toBe('');
  });

  it.each(['red', '#12345', '#1234567', 'url(x)', '#GGGGGG', '#123456; background:url(x)'])(
    'falls back to the default colour for %j (it lands in an inline style)',
    async (primary_color) => {
      const b = await loadBranding(client({ data: { primary_color }, error: null }));
      expect(b.primaryColor).toBe(DEFAULT_BRANDING.primaryColor);
    },
  );

  it('uses defaults for blank fields', async () => {
    const b = await loadBranding(client({ data: { platform_name: '', tagline: '' }, error: null }));
    expect(b.platformName).toBe(DEFAULT_BRANDING.platformName);
    expect(b.tagline).toBe(DEFAULT_BRANDING.tagline);
    expect(b.supportEmail).toBe('');
  });

  it('returns the defaults on an RPC error, an empty result, or a thrown error', async () => {
    expect(await loadBranding(client({ data: null, error: { message: 'x' } }))).toEqual(DEFAULT_BRANDING);
    expect(await loadBranding(client({ data: null, error: null }))).toEqual(DEFAULT_BRANDING);
    expect(
      await loadBranding({
        rpc: () => {
          throw new Error('boom');
        },
      }),
    ).toEqual(DEFAULT_BRANDING);
  });
});

describe('renderEmail', () => {
  it('escapes the title, platform name, preheader, footer note, logo URL and support address', () => {
    const html = renderEmail(
      { ...B, platformName: '<b>Acme</b>', logoUrl: 'https://x.example/l.png?a=1&b="2"', supportEmail: 'a"@b.example' },
      { title: '<script>t</script>', preheader: '<i>pre</i>', bodyHtml: '<p>body</p>', footerNote: '<u>foot</u>' },
    );
    for (const raw of ['<script>t</script>', '<b>Acme</b>', '<i>pre</i>', '<u>foot</u>', 'b="2"', 'a"@b.example']) {
      expect(html).not.toContain(raw);
    }
    expect(html).toContain('&lt;script&gt;t&lt;/script&gt;');
  });

  it('passes the body through unescaped (callers escape it) and uses the brand colour', () => {
    const html = renderEmail(B, { title: 'T', bodyHtml: '<p class="x">hello</p>' });
    expect(html).toContain('<p class="x">hello</p>');
    expect(html).toContain('background:#112233');
  });

  it('omits the logo, preheader, footer note and support link when not provided', () => {
    const html = renderEmail(B, { title: 'T', bodyHtml: '' });
    expect(html).not.toContain('<img');
    expect(html).not.toContain('display:none');
    expect(html).not.toContain('mailto:');
  });

  it('shows the support mailto when configured', () => {
    expect(renderEmail({ ...B, supportEmail: 'help@acme.example' }, { title: 'T', bodyHtml: '' })).toContain(
      'mailto:help@acme.example',
    );
  });
});

describe('sendEmail', () => {
  const args = { apiKey: 'k', from: 'f@x.example', to: ['a@x.example', 'b@x.example'], subject: 'S', html: '<p>h</p>' };

  it('posts to Resend with the bearer key and returns null on success', async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal('fetch', fetchMock);
    expect(await sendEmail({ ...args, attachments: [{ filename: 'a.pdf', content: 'QQ==' }] })).toBeNull();
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://api.resend.com/emails');
    expect(init.method).toBe('POST');
    expect((init.headers as Record<string, string>).Authorization).toBe('Bearer k');
    expect(JSON.parse(init.body as string)).toEqual({
      from: 'f@x.example',
      to: ['a@x.example', 'b@x.example'],
      subject: 'S',
      html: '<p>h</p>',
      attachments: [{ filename: 'a.pdf', content: 'QQ==' }],
    });
  });

  it('returns the status and a truncated body on a non-2xx response', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: false, status: 422, text: async () => 'x'.repeat(2000) }));
    const err = await sendEmail(args);
    expect(err?.startsWith('Resend 422: ')).toBe(true);
    expect(err!.length).toBe('Resend 422: '.length + 500);
  });

  it('never throws: a network failure comes back as text', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('network down')));
    expect(await sendEmail(args)).toBe('network down');
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue('weird'));
    expect(await sendEmail(args)).toBe('send failed');
  });
});
