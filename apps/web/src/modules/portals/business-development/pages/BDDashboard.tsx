import { useEffect, useState } from "react";
import { Box, Card, CardContent, Chip, CircularProgress, LinearProgress, Stack, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
import { Link as RouterLink } from "react-router-dom";
import { supabase } from "../../../../lib/supabaseClient";

// BD Dashboard -- KPI summary for the Business Development portal home.
//
// This intentionally does NOT re-derive every metric from scratch: the
// module already has dedicated report pages (Pipeline, Win/Loss, Lead
// Source, Proposal Status, Revenue Forecast) with the detailed
// breakdowns. This dashboard pulls the same underlying tables but keeps
// aggregation to top-line numbers + a short leaders list, and links out
// to the full reports for drill-down instead of duplicating their logic.
//
// Currency is hardcoded to USD, matching the same simplification already
// made in the sibling report pages (see PipelineReport.tsx).

interface Lead {
  id: string;
  source_id: string;
  status: string;
  bd_lead_sources?: { name: string } | null;
}

interface Opportunity {
  id: string;
  stage: string;
  estimated_value: number;
  probability: number;
}

interface Proposal {
  id: string;
  status: string;
}

const OPEN_STAGES_EXCLUDED = ["closed_won", "closed_lost"];
// Matches ProposalApprovals.tsx's query exactly ("sent" is excluded --
// that's awaiting the client's decision, not an internal approval action)
// so this KPI's count always matches what clicking through actually shows.
const PENDING_PROPOSAL_STATUSES = ["in_review", "pending_approval"];

export default function BDDashboard() {
  const [loading, setLoading] = useState(true);
  const [leads, setLeads] = useState<Lead[]>([]);
  const [opportunities, setOpportunities] = useState<Opportunity[]>([]);
  const [proposals, setProposals] = useState<Proposal[]>([]);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const [leadsRes, oppsRes, propsRes] = await Promise.all([
        supabase.from("bd_leads").select("id, source_id, status, bd_lead_sources(name)"),
        supabase.from("bd_opportunities").select("id, stage, estimated_value, probability"),
        supabase.from("bd_proposals").select("id, status"),
      ]);
      // PostgREST returns nested to-one joins as arrays in this schema
      // (same quirk seen elsewhere in the app) -- normalize.
      const normalizedLeads = ((leadsRes.data as any[]) || []).map((l) => ({
        ...l,
        bd_lead_sources: Array.isArray(l.bd_lead_sources) ? l.bd_lead_sources[0] ?? null : l.bd_lead_sources ?? null,
      }));
      setLeads(normalizedLeads as Lead[]);
      setOpportunities(((oppsRes.data as Opportunity[]) || []));
      setProposals(((propsRes.data as Proposal[]) || []));
      setLoading(false);
    };
    fetch();
  }, []);

  if (loading) {
    return (
      <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}>
        <CircularProgress />
      </Box>
    );
  }

  // Pipeline: open (not yet closed) opportunities only.
  const openOpps = opportunities.filter((o) => !OPEN_STAGES_EXCLUDED.includes(o.stage));
  const pipelineValue = openOpps.reduce((s, o) => s + Number(o.estimated_value), 0);
  const weightedPipeline = openOpps.reduce((s, o) => s + Number(o.estimated_value) * (o.probability / 100), 0);

  // Win rate: closed opportunities only.
  const won = opportunities.filter((o) => o.stage === "closed_won");
  const lost = opportunities.filter((o) => o.stage === "closed_lost");
  const closedTotal = won.length + lost.length;
  const winRate = closedTotal > 0 ? (won.length / closedTotal) * 100 : 0;

  // Proposals pending a decision -- excludes draft (not yet submitted)
  // and resolved statuses (accepted/rejected/expired).
  const proposalsPending = proposals.filter((p) => PENDING_PROPOSAL_STATUSES.includes(p.status));

  // Leads by source, top 5 -- full breakdown lives in Lead Source Report.
  const sourceMap: Record<string, number> = {};
  leads.forEach((l) => {
    const name = l.bd_lead_sources?.name || "Unknown";
    sourceMap[name] = (sourceMap[name] || 0) + 1;
  });
  const topSources = Object.entries(sourceMap)
    .map(([name, count]) => ({ name, count }))
    .sort((a, b) => b.count - a.count)
    .slice(0, 5);

  // Funnel: count of records at each stage of the BD lifecycle. This is
  // a snapshot of current totals per table, not a strict 1:1 conversion
  // chain (a proposal isn't guaranteed to trace back to a specific lead)
  // -- same approximation already used by ProposalStatusReport's "avg
  // days" calc elsewhere in this module.
  const funnel = [
    { label: "Leads", count: leads.length, to: "/business-development/leads" },
    { label: "Opportunities", count: opportunities.length, to: "/business-development/opportunities" },
    { label: "Proposals", count: proposals.length, to: "/business-development/proposals" },
    { label: "Won", count: won.length, to: "/business-development/reports/win-loss" },
  ];
  const funnelMax = Math.max(1, ...funnel.map((f) => f.count));

  const kpiCards = [
    { label: "Open Pipeline Value", value: `USD ${pipelineValue.toLocaleString()}`, to: "/business-development/reports/pipeline", bg: undefined },
    { label: "Weighted Pipeline", value: `USD ${weightedPipeline.toLocaleString()}`, to: "/business-development/reports/pipeline", bg: "primary.light" },
    { label: "Win Rate", value: `${winRate.toFixed(1)}%`, to: "/business-development/reports/win-loss", bg: winRate >= 50 ? "success.light" : undefined },
    { label: "Proposals Pending", value: String(proposalsPending.length), to: "/business-development/proposals/approvals", bg: proposalsPending.length > 0 ? "warning.light" : undefined },
  ];

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>
        BD Dashboard
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Pipeline, win rate, leads by source, proposals pending, and the lead → opportunity → proposal
        → won funnel. Each card links to the full report for drill-down.
      </Typography>

      <Box sx={{ display: "flex", gap: 2, mb: 3, flexWrap: "wrap" }}>
        {kpiCards.map((k) => (
          <Card
            key={k.label}
            component={RouterLink}
            to={k.to}
            variant="outlined"
            sx={{ minWidth: 200, flex: "1 1 200px", textDecoration: "none", bgcolor: k.bg, transition: "box-shadow 0.15s", "&:hover": { boxShadow: 3 } }}
          >
            <CardContent>
              <Typography variant="caption" color={k.bg ? undefined : "text.secondary"}>
                {k.label}
              </Typography>
              <Typography variant="h5" fontWeight={700}>
                {k.value}
              </Typography>
            </CardContent>
          </Card>
        ))}
      </Box>

      <Box sx={{ display: "flex", gap: 2, flexWrap: "wrap" }}>
        <Card variant="outlined" sx={{ flex: "2 1 500px" }}>
          <CardContent>
            <Typography variant="subtitle1" fontWeight={700} gutterBottom>
              Pipeline funnel
            </Typography>
            <Stack spacing={1.5} sx={{ mt: 1 }}>
              {funnel.map((f) => (
                <Box key={f.label}>
                  <Box sx={{ display: "flex", justifyContent: "space-between", mb: 0.5 }}>
                    <Typography
                      variant="body2"
                      component={RouterLink}
                      to={f.to}
                      sx={{ color: "text.primary", textDecoration: "none", fontWeight: 600, "&:hover": { textDecoration: "underline" } }}
                    >
                      {f.label}
                    </Typography>
                    <Typography variant="body2" color="text.secondary">
                      {f.count}
                    </Typography>
                  </Box>
                  <LinearProgress
                    variant="determinate"
                    value={(f.count / funnelMax) * 100}
                    sx={{ height: 10, borderRadius: 1 }}
                    color={f.label === "Won" ? "success" : "primary"}
                  />
                </Box>
              ))}
            </Stack>
          </CardContent>
        </Card>

        <Card variant="outlined" sx={{ flex: "1 1 320px" }}>
          <CardContent>
            <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 1 }}>
              <Typography variant="subtitle1" fontWeight={700}>
                Leads by source
              </Typography>
              <Typography
                variant="caption"
                component={RouterLink}
                to="/business-development/reports/lead-source"
                sx={{ color: "primary.main", textDecoration: "none", "&:hover": { textDecoration: "underline" } }}
              >
                Full report →
              </Typography>
            </Box>
            {topSources.length === 0 ? (
              <Typography variant="body2" color="text.secondary" sx={{ py: 2 }}>
                No leads yet.
              </Typography>
            ) : (
              <Table size="small">
                <TableHead>
                  <TableRow>
                    <TableCell>Source</TableCell>
                    <TableCell align="right">Leads</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {topSources.map((s) => (
                    <TableRow key={s.name}>
                      <TableCell>
                        <Chip label={s.name} size="small" variant="outlined" />
                      </TableCell>
                      <TableCell align="right">{s.count}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </CardContent>
        </Card>
      </Box>
    </Box>
  );
}