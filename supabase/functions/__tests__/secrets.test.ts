import { describe, expect, it } from 'vitest';
import { secretsMatch } from '../_shared/secrets';

describe('secretsMatch', () => {
  it('matches identical secrets', async () => {
    expect(await secretsMatch('correct-horse', 'correct-horse')).toBe(true);
  });
  it('rejects different secrets, prefixes and different lengths', async () => {
    expect(await secretsMatch('correct-hors', 'correct-horse')).toBe(false);
    expect(await secretsMatch('correct-horse!', 'correct-horse')).toBe(false);
    expect(await secretsMatch('', 'correct-horse')).toBe(false);
  });
});
