import { RouteObject } from "react-router-dom";
import BDPlaceholder from "./pages/Placeholder";

const ph = (title: string, desc: string, module = "Business Development") => (
  <BDPlaceholder title={title} description={desc} module={module} />
);

export const businessDevelopmentRoutes: RouteObject[] = [
  {
    path: "business-development",
    children: [
      { path: "dashboard", element: ph("BD Dashboard", "KPIs: Pipeline value, win rate, leads by source, proposals pending approval, revenue forecast by month. Charts: funnel (lead->opportunity->proposal->won), pipeline value by stage.", "Dashboard") },

      // Lead Management
      { path: "leads", element: ph("Leads", "Table: company, contact, source, status, estimated value, assigned_to. Filters: status/source/date. Row -> detail with activities.", "Lead Management") },
      { path: "leads/new", element: ph("New Lead", "Form: company, contact, email/phone, source (lookup), status, estimated value, notes. Source dropdown backed by bd_lead_sources admin.", "Lead Management") },
      { path: "leads/qualified", element: ph("Qualified Leads", "Filtered view: status=qualified. Convert to opportunity button.", "Lead Management") },
      { path: "leads/import", element: ph("Import Leads", "CSV upload mapping to lead fields, validation, duplicate check.", "Lead Management") },

      // Opportunities
      { path: "opportunities", element: ph("Opportunities", "Table: title, client, stage, probability, value, expected close. Weighted value = value * probability.", "Opportunity") },
      { path: "opportunities/pipeline", element: ph("Pipeline Board", "Board grouped by bd_opportunity_stages order_index. Columns = stages. Drag opportunity to change stage, auto update probability.", "Opportunity") },
      { path: "opportunities/new", element: ph("New Opportunity", "Form: title, client (lookup), lead link, stage, probability auto from stage default, value, close date.", "Opportunity") },

      // Proposals
      { path: "proposals", element: ph("Proposals", "Table: proposal_no, title, client, opportunity, status, value, valid_until. Version history.", "Proposals") },
      { path: "proposals/new", element: ph("New Proposal", "Form: title, client, opportunity link, type (lookup), value, currency, template, content editor. Auto proposal_no BD-P-YYYY-0001.", "Proposals") },
      { path: "proposals/approvals", element: ph("Proposal Approvals", "Approval queue for proposals needing manager approval before sending. Same pattern as Material Request Approval.", "Proposals") },
      { path: "proposals/templates", element: ph("Proposal Templates", "Manage reusable templates with placeholders e.g. {{client_name}} {{scope}}.", "Proposals") },
      { path: "proposals/tracking", element: ph("Proposal Tracking", "Status timeline: draft -> review -> approved -> sent -> accepted/rejected. Activity log per proposal.", "Proposals") },

      // Clients
      { path: "clients", element: ph("Clients", "Table: name, category, industry, active. Client detail shows contacts, opportunities, proposals, activities.", "Client Management") },
      { path: "clients/contacts", element: ph("Contacts", "Table: client, name, email, phone, position, primary flag. Linked to client.", "Client Management") },
      { path: "clients/activities", element: ph("Activities & Meetings", "Timeline: calls, meetings, emails, notes linked to client/lead/opportunity/proposal. Create activity form.", "Client Management") },

      // Tenders
      { path: "tenders", element: ph("Tenders", "Table: tender_no, title, client, status, deadline, value. Highlight near deadline.", "Tender Management") },
      { path: "tenders/new", element: ph("New Tender", "Form: title, type, client, deadline, value, portal_url, description. Link to proposal later.", "Tender Management") },
      { path: "tenders/submissions", element: ph("Tender Submissions", "List submissions, status, documents uploaded, awarded/lost update.", "Tender Management") },
      { path: "tenders/tracking", element: ph("Tender Tracking", "Calendar view of deadlines, status report, win/loss by client.", "Tender Management") },

      // Reports
      { path: "reports/pipeline", element: ph("Pipeline Report", "Pipeline value by stage, weighted pipeline, expected close date range filter.", "Reports") },
      { path: "reports/win-loss", element: ph("Win/Loss Report", "Win rate %, reason analysis, by client category / proposal type.", "Reports") },
      { path: "reports/proposal-status", element: ph("Proposal Status", "Count/value by status, avg time in each status.", "Reports") },
      { path: "reports/lead-source", element: ph("Lead Source Report", "Leads count/value by source, conversion rate source->opportunity.", "Reports") },
      { path: "reports/forecast", element: ph("Revenue Forecast", "Monthly forecast weighted by probability, group by stage/month. Uses bd_opportunity_stages probability.", "Reports") },

      // Admin - lookup tables backing dropdowns (same pattern as Material Classification & IT Support Categories)
      { path: "admin/lead-sources", element: ph("Lead Sources", "CRUD: name, description, is_active. Backs New Lead dropdown. Example: Referral, Website, Tender Portal.", "Admin") },
      { path: "admin/lead-statuses", element: ph("Lead Statuses", "Manage status labels, order, color. Could be enum extension table.", "Admin") },
      { path: "admin/opportunity-stages", element: ph("Opportunity Stages", "CRUD: stage enum, label, order_index, default probability, color. Drives Kanban and weighted forecast. Sister to IT SLA Policies.", "Admin") },
      { path: "admin/proposal-types", element: ph("Proposal Types", "CRUD: Technical, Financial, Combined, etc.", "Admin") },
      { path: "admin/proposal-statuses", element: ph("Proposal Statuses", "Status workflow config, labels, color.", "Admin") },
      { path: "admin/client-categories", element: ph("Client Categories", "Category: Government, Private, NGO, etc. Backs client form.", "Admin") },
      { path: "admin/tender-types", element: ph("Tender Types", "Type: Public, Private, International.", "Admin") },
    ],
  },
];
