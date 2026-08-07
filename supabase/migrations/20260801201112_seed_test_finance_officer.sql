insert into finance_team_members (tenant_id, user_id, role)
values ('00000000-0000-0000-0000-000000000001', 'ed9cd87d-7649-486c-958b-36114271a0b2', 'finance')
on conflict do nothing;
