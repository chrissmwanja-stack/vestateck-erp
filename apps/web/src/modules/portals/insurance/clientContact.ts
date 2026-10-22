// Pure helpers for editing a client's contact details (name, email, phone).
// These live on the shared client master (bd_clients), so insurance edits them in place.

export interface ClientContact {
  name: string;
  email: string | null;
  phone: string | null;
}

export interface ContactForm {
  name: string;
  email: string;
  phone: string;
}

export type ContactErrors = Partial<Record<keyof ContactForm, string>>;

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
// Digits with an optional leading +, once spaces, dashes, dots and brackets are removed.
const PHONE = /^\+?\d{7,15}$/;

export function validateClientContact(form: ContactForm): ContactErrors {
  const errors: ContactErrors = {};
  const name = form.name.trim();
  if (!name) errors.name = 'Enter the client name.';
  else if (name.length > 200) errors.name = 'Keep the name under 200 characters.';
  const email = form.email.trim();
  if (email && !EMAIL.test(email)) errors.email = 'Enter a valid email address, or leave it blank.';
  const phone = form.phone.trim();
  if (phone && !PHONE.test(phone.replace(/[\s\-().]/g, ''))) errors.phone = 'Enter a valid phone number, for example +256 700 000000, or leave it blank.';
  return errors;
}

/** The form's starting values for a stored client. */
export function contactToForm(c: ClientContact | null): ContactForm {
  return { name: c?.name ?? '', email: c?.email ?? '', phone: c?.phone ?? '' };
}

/**
 * Only the fields that changed, trimmed, with a blank email or phone stored as null.
 * Empty when nothing changed, so an untouched save sends no write.
 */
export function contactPatch(original: ClientContact | null, form: ContactForm): Partial<ClientContact> {
  const patch: Partial<ClientContact> = {};
  const name = form.name.trim();
  const email = form.email.trim() || null;
  const phone = form.phone.trim() || null;
  if (name !== (original?.name ?? '')) patch.name = name;
  if (email !== (original?.email?.trim() || null)) patch.email = email;
  if (phone !== (original?.phone?.trim() || null)) patch.phone = phone;
  return patch;
}
