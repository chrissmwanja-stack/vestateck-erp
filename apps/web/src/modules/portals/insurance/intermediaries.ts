// Intermediary register rules (agents and sub-agents, slice 1: no money).
//
// These mirror the server checks in 20261017140000_ins_intermediaries.sql so the form
// can explain a problem before it is saved. The server stays the enforcement point.
// Nothing here posts anything; commission and withholding come in slice 3.

export type IntermediaryCategory = 'insurer_appointed_agent' | 'independent_broker' | 'sub_agent' | 'referral_partner';
export type IntermediaryStatus = 'pending_verification' | 'active' | 'suspended' | 'expired' | 'terminated';

export interface Intermediary {
  id: string;
  code: string;
  kind: 'individual' | 'business';
  name: string;
  category: IntermediaryCategory;
  contact_email: string | null;
  contact_phone: string | null;
  parent_id: string | null;
  licence_ref: string | null;
  licence_authority: string | null;
  licence_valid_from: string | null;
  licence_valid_to: string | null;
  appointment_ref: string | null;
  authorisation_basis: string | null;
  authorisation_reference: string | null;
  status: IntermediaryStatus;
  last_changed_by: string | null;
  verified_by: string | null;
  verified_at: string | null;
}

export const CATEGORY_LABEL: Record<IntermediaryCategory, string> = {
  insurer_appointed_agent: 'Insurer-appointed agent',
  independent_broker: 'Independent broker',
  sub_agent: 'Sub-agent',
  referral_partner: 'Referral partner',
};

export const STATUS_LABEL: Record<IntermediaryStatus, string> = {
  pending_verification: 'Pending verification',
  active: 'Active',
  suspended: 'Suspended',
  expired: 'Licence expired',
  terminated: 'Terminated',
};

/** Every category except a referral partner needs a licence on record. */
export const needsLicence = (category: IntermediaryCategory): boolean => category !== 'referral_partner';

/** An insurer-appointed agent needs the insurer's appointment, as well as its licence. */
export const needsAppointment = (category: IntermediaryCategory): boolean => category === 'insurer_appointed_agent';

/** A sub-agent must sit under a parent, and the basis for the parent's authority must be recorded. */
export const needsParent = (category: IntermediaryCategory): boolean => category === 'sub_agent';

export interface IntermediaryForm {
  code: string;
  name: string;
  kind: 'individual' | 'business';
  category: IntermediaryCategory;
  parent_id: string | null;
  licence_ref: string;
  licence_authority: string;
  licence_valid_from: string;
  licence_valid_to: string;
  appointment_ref: string;
  authorisation_basis: string;
  authorisation_reference: string;
}

const blank = (v: string | null | undefined): boolean => !v || v.trim() === '';

/**
 * Returns the problems that stop a save, in the order the form shows them.
 * `today` is an ISO date (YYYY-MM-DD) so the check is deterministic in tests.
 */
export function saveProblems(form: IntermediaryForm, parents: Intermediary[], selfId: string | null, today: string): string[] {
  const problems: string[] = [];
  if (blank(form.code)) problems.push('Give the intermediary a reference code.');
  if (blank(form.name)) problems.push('Give the intermediary a name.');

  if (needsLicence(form.category)) {
    if (blank(form.licence_ref) || blank(form.licence_authority) || blank(form.licence_valid_to)) {
      problems.push('A licence needs its reference, issuing authority and expiry date.');
    } else if (form.licence_valid_to < today) {
      problems.push('The licence has already expired.');
    }
    if (!blank(form.licence_valid_from) && !blank(form.licence_valid_to) && form.licence_valid_to < form.licence_valid_from) {
      problems.push('The licence expiry is before its start date.');
    }
  }

  if (needsAppointment(form.category) && blank(form.appointment_ref)) {
    problems.push("An insurer-appointed agent needs the insurer's appointment reference, separate from its licence.");
  }

  if (needsParent(form.category)) {
    if (!form.parent_id) problems.push('A sub-agent must be placed under a parent intermediary.');
    if (blank(form.authorisation_basis) || blank(form.authorisation_reference)) {
      problems.push("Record the basis on which the parent may appoint this sub-agent, and its reference.");
    }
  }

  if (form.parent_id) {
    const parent = parents.find((p) => p.id === form.parent_id);
    if (!parent) {
      problems.push('The chosen parent is not on the register.');
    } else if (parent.status !== 'active') {
      problems.push('The parent must be verified and active before it can be linked.');
    } else if (parent.category === 'referral_partner') {
      problems.push('A referral partner cannot appoint or be a parent.');
    }
    if (selfId && parentWouldLoop(form.parent_id, selfId, parents)) {
      problems.push('That parent sits below this intermediary in the chain.');
    }
  }
  return problems;
}

/**
 * True when making `candidateId` the parent of `selfId` would create a loop: the
 * candidate is the record itself, or the record is already one of the candidate's
 * ancestors. Walks up the parent chain with a guard, so bad data cannot hang it.
 */
export function parentWouldLoop(candidateId: string, selfId: string, all: Intermediary[]): boolean {
  if (candidateId === selfId) return true;
  const byId = new Map(all.map((i) => [i.id, i]));
  const seen = new Set<string>();
  let cursor: string | null = candidateId;
  while (cursor && !seen.has(cursor)) {
    if (cursor === selfId) return true;
    seen.add(cursor);
    cursor = byId.get(cursor)?.parent_id ?? null;
  }
  return false;
}

/** Parents offered in the dropdown: active, not a referral partner, and not a loop. */
export function parentChoices(all: Intermediary[], selfId: string | null): Intermediary[] {
  return all.filter(
    (p) =>
      p.status === 'active' &&
      p.category !== 'referral_partner' &&
      p.id !== selfId &&
      !(selfId && parentWouldLoop(p.id, selfId, all)),
  );
}

/**
 * True when an edit changes a credential, the category or the parent. The server
 * then sends the record back to pending verification.
 */
export function changeNeedsReverification(before: Intermediary, after: Pick<Intermediary,
  'category' | 'parent_id' | 'licence_ref' | 'licence_authority' | 'licence_valid_from' | 'licence_valid_to' | 'appointment_ref' | 'authorisation_basis' | 'authorisation_reference'>): boolean {
  const keys = [
    'category', 'parent_id', 'licence_ref', 'licence_authority', 'licence_valid_from',
    'licence_valid_to', 'appointment_ref', 'authorisation_basis', 'authorisation_reference',
  ] as const;
  return keys.some((k) => (before[k] ?? null) !== (after[k] ?? null));
}

/** Verification needs a different manager from whoever last changed the record. */
export function canVerify(row: Intermediary, actorId: string | null): { ok: boolean; reason?: string } {
  if (row.status !== 'pending_verification') return { ok: false, reason: 'Only a pending intermediary can be verified.' };
  if (actorId && row.last_changed_by === actorId) {
    return { ok: false, reason: 'The person who last changed this record cannot verify it. Another manager must.' };
  }
  return { ok: true };
}

/** Status moves the server allows, from the current status. */
export function allowedStatusMoves(status: IntermediaryStatus): IntermediaryStatus[] {
  switch (status) {
    case 'active':
      return ['suspended', 'expired', 'terminated'];
    case 'suspended':
      return ['active', 'terminated'];
    case 'expired':
      return ['terminated'];
    case 'pending_verification':
      return ['terminated'];
    default:
      return [];
  }
}

/** Suspending or terminating needs a reason. */
export const statusNeedsNote = (to: IntermediaryStatus): boolean => to === 'suspended' || to === 'terminated';
