import { supabase } from '../../lib/supabaseClient';

// Shared by InviteMember.tsx and CompaniesConsole.tsx -- both render an
// invitations table with the same two actions.

export async function resendInvite(invitationId: string): Promise<{ error: string | null }> {
  const { error } = await supabase.functions.invoke('resend-invite', {
    body: { invitation_id: invitationId },
  });
  return { error: error ? error.message : null };
}

export async function revokeInvite(invitationId: string): Promise<{ error: string | null }> {
  const { error } = await supabase.rpc('revoke_invitation', { p_invitation_id: invitationId });
  return { error: error ? error.message : null };
}