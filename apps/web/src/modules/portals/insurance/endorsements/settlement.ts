// The settlement workflow for an endorsed position: the items a posted endorsement
// left behind (AR to collect, insurer payables to pay, recovery items), and the
// settlements that cover them. Read model + write wrappers; all money math and the
// guards live server-side (fin_record_settlement / fin_void_settlement).
import { rpc } from '../db';

export interface EndorsementSettlementItem {
  id: string;
  source_type: string;
  document_no: string;
  control_role: string;
  side: 'receivable' | 'payable';
  amount: number;
  outstanding: number;
  currency: string;
  party_account_id: string;
  party_name: string;
  settlement_status: string;
}

export interface EndorsementSettlement {
  id: string;
  settlement_no: string;
  direction: 'in' | 'out';
  amount: number;
  currency: string;
  settlement_date: string;
  reference: string | null;
  status: string;
  party_account_id: string;
  party_name: string;
  reconciled: boolean;
}

export interface EndorsementSettlementPosition {
  endorsement_id: string;
  endorsement_no: string | null;
  policy_id: string;
  policy_no: string;
  currency: string;
  status: string;
  items: EndorsementSettlementItem[];
  settlements: EndorsementSettlement[];
}

/** What is open on this endorsement and what settlements cover it. */
export async function endorsementSettlementPosition(endorsementId: string): Promise<EndorsementSettlementPosition> {
  return rpc<EndorsementSettlementPosition>('ins_endorsement_settlement_position', {
    p_endorsement_id: endorsementId,
  });
}

/**
 * Records one settlement covering one open item. The bank account and party are
 * passed explicitly; the server re-derives everything else, including what the
 * item is allowed to be paid from.
 */
export async function settleEndorsementItem(input: {
  bankAccountId: string;
  direction: 'in' | 'out';
  partyAccountId: string;
  amount: number;
  settlementDate: string;
  itemId: string;
  itemAmount: number;
  reference?: string | null;
  notes?: string | null;
}) {
  return rpc<EndorsementSettlement>('fin_record_settlement', {
    p_bank_account_id: input.bankAccountId,
    p_direction: input.direction,
    p_party_account_id: input.partyAccountId,
    p_amount: input.amount,
    p_settlement_date: input.settlementDate,
    p_allocations: [{ open_item_id: input.itemId, amount: input.itemAmount }],
    p_reference: input.reference ?? null,
    p_notes: input.notes ?? null,
  });
}

/** Reverses a posted settlement. Reversal reopens the item and un-earns the commission it earned. */
export async function voidSettlement(input: { settlementId: string; reason: string }) {
  return rpc<EndorsementSettlement>('fin_void_settlement', {
    p_settlement_id: input.settlementId,
    p_reason: input.reason,
  });
}

/** A receivable item settles with client money coming in; a payable item goes out. */
export function directionFor(item: EndorsementSettlementItem): 'in' | 'out' {
  return item.side === 'receivable' ? 'in' : 'out';
}
