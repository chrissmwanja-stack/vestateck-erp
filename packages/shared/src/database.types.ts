export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.15"
  }
  public: {
    Tables: {
      access_requests: {
        Row: {
          access_level: string | null
          created_at: string
          decided_at: string | null
          decided_by: string | null
          decision_notes: string | null
          id: string
          justification: string | null
          requested_by: string
          resource: string
          status: string
          tenant_id: string
          updated_at: string
        }
        Insert: {
          access_level?: string | null
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          decision_notes?: string | null
          id?: string
          justification?: string | null
          requested_by: string
          resource: string
          status?: string
          tenant_id: string
          updated_at?: string
        }
        Update: {
          access_level?: string | null
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          decision_notes?: string | null
          id?: string
          justification?: string | null
          requested_by?: string
          resource?: string
          status?: string
          tenant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "access_requests_decided_by_fkey"
            columns: ["decided_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "access_requests_requested_by_fkey"
            columns: ["requested_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "access_requests_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      account_categories: {
        Row: {
          code: string
          created_at: string
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        Insert: {
          code: string
          created_at?: string
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
        }
        Update: {
          code?: string
          created_at?: string
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "account_categories_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      accounts: {
        Row: {
          account_code: string
          account_type: string
          address: string | null
          bank_account_name: string | null
          bank_account_number: string | null
          bank_branch: string | null
          bank_name: string | null
          business_registration_number: string | null
          category_id: string | null
          contact_email: string | null
          contact_name: string | null
          contact_phone: string | null
          created_at: string
          id: string
          is_active: boolean
          license_expiry: string | null
          license_number: string | null
          name: string
          swift_code: string | null
          tax_id: string | null
          tenant_id: string
          updated_at: string
        }
        Insert: {
          account_code: string
          account_type: string
          address?: string | null
          bank_account_name?: string | null
          bank_account_number?: string | null
          bank_branch?: string | null
          bank_name?: string | null
          business_registration_number?: string | null
          category_id?: string | null
          contact_email?: string | null
          contact_name?: string | null
          contact_phone?: string | null
          created_at?: string
          id?: string
          is_active?: boolean
          license_expiry?: string | null
          license_number?: string | null
          name: string
          swift_code?: string | null
          tax_id?: string | null
          tenant_id: string
          updated_at?: string
        }
        Update: {
          account_code?: string
          account_type?: string
          address?: string | null
          bank_account_name?: string | null
          bank_account_number?: string | null
          bank_branch?: string | null
          bank_name?: string | null
          business_registration_number?: string | null
          category_id?: string | null
          contact_email?: string | null
          contact_name?: string | null
          contact_phone?: string | null
          created_at?: string
          id?: string
          is_active?: boolean
          license_expiry?: string | null
          license_number?: string | null
          name?: string
          swift_code?: string | null
          tax_id?: string | null
          tenant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "accounts_category_id_fkey"
            columns: ["category_id"]
            isOneToOne: false
            referencedRelation: "account_categories"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "accounts_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      advance_payment_applications: {
        Row: {
          advance_payment_id: string
          applied_amount: number
          applied_at: string
          applied_by: string
          id: string
          reference_id: string
          reference_type: string
        }
        Insert: {
          advance_payment_id: string
          applied_amount: number
          applied_at?: string
          applied_by?: string
          id?: string
          reference_id: string
          reference_type: string
        }
        Update: {
          advance_payment_id?: string
          applied_amount?: number
          applied_at?: string
          applied_by?: string
          id?: string
          reference_id?: string
          reference_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "advance_payment_applications_advance_payment_id_fkey"
            columns: ["advance_payment_id"]
            isOneToOne: false
            referencedRelation: "advance_payments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "advance_payment_applications_advance_payment_id_fkey"
            columns: ["advance_payment_id"]
            isOneToOne: false
            referencedRelation: "v_advance_payments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "advance_payment_applications_applied_by_fkey"
            columns: ["applied_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
        ]
      }
      advance_payments: {
        Row: {
          account_id: string
          amount: number
          bank_account: string | null
          created_at: string
          currency: string
          description: string | null
          direction: string
          id: string
          payment_date: string
          payment_method: string
          recorded_by: string
          tenant_id: string
        }
        Insert: {
          account_id: string
          amount: number
          bank_account?: string | null
          created_at?: string
          currency?: string
          description?: string | null
          direction: string
          id?: string
          payment_date: string
          payment_method: string
          recorded_by?: string
          tenant_id: string
        }
        Update: {
          account_id?: string
          amount?: number
          bank_account?: string | null
          created_at?: string
          currency?: string
          description?: string | null
          direction?: string
          id?: string
          payment_date?: string
          payment_method?: string
          recorded_by?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "advance_payments_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "advance_payments_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "v_trial_balance"
            referencedColumns: ["account_id"]
          },
          {
            foreignKeyName: "advance_payments_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "v_vendor_evaluation"
            referencedColumns: ["vendor_account_id"]
          },
          {
            foreignKeyName: "advance_payments_recorded_by_fkey"
            columns: ["recorded_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "advance_payments_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      app_users: {
        Row: {
          created_at: string
          department_id: string | null
          email: string
          id: string
          is_company_admin: boolean
          is_platform_admin: boolean
          name: string
          role_title: string | null
          tenant_id: string
        }
        Insert: {
          created_at?: string
          department_id?: string | null
          email: string
          id: string
          is_company_admin?: boolean
          is_platform_admin?: boolean
          name: string
          role_title?: string | null
          tenant_id: string
        }
        Update: {
          created_at?: string
          department_id?: string | null
          email?: string
          id?: string
          is_company_admin?: boolean
          is_platform_admin?: boolean
          name?: string
          role_title?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "app_users_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "app_users_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      approval_actions: {
        Row: {
          acted_at: string
          acted_on_behalf_of: string | null
          approver_id: string
          comment: string | null
          decision: string
          id: string
          invoice_request_id: string | null
          request_id: string | null
          workflow_stage_id: string
        }
        Insert: {
          acted_at?: string
          acted_on_behalf_of?: string | null
          approver_id: string
          comment?: string | null
          decision: string
          id?: string
          invoice_request_id?: string | null
          request_id?: string | null
          workflow_stage_id: string
        }
        Update: {
          acted_at?: string
          acted_on_behalf_of?: string | null
          approver_id?: string
          comment?: string | null
          decision?: string
          id?: string
          invoice_request_id?: string | null
          request_id?: string | null
          workflow_stage_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "approval_actions_acted_on_behalf_of_fkey"
            columns: ["acted_on_behalf_of"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "approval_actions_approver_id_fkey"
            columns: ["approver_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "approval_actions_invoice_request_id_fkey"
            columns: ["invoice_request_id"]
            isOneToOne: false
            referencedRelation: "invoice_requests"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "approval_actions_request_id_fkey"
            columns: ["request_id"]
            isOneToOne: false
            referencedRelation: "requests"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "approval_actions_request_id_fkey"
            columns: ["request_id"]
            isOneToOne: false
            referencedRelation: "v_request_tracking"
            referencedColumns: ["request_id"]
          },
          {
            foreignKeyName: "approval_actions_workflow_stage_id_fkey"
            columns: ["workflow_stage_id"]
            isOneToOne: false
            referencedRelation: "workflow_stages"
            referencedColumns: ["id"]
          },
        ]
      }
      approval_assignments: {
        Row: {
          created_at: string
          id: string
          scope_id: string | null
          scope_type: string
          tenant_id: string
          threshold_max: number | null
          user_id: string
          workflow_stage_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          scope_id?: string | null
          scope_type?: string
          tenant_id: string
          threshold_max?: number | null
          user_id: string
          workflow_stage_id: string
        }
        Update: {
          created_at?: string
          id?: string
          scope_id?: string | null
          scope_type?: string
          tenant_id?: string
          threshold_max?: number | null
          user_id?: string
          workflow_stage_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "approval_assignments_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "approval_assignments_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "approval_assignments_workflow_stage_id_fkey"
            columns: ["workflow_stage_id"]
            isOneToOne: false
            referencedRelation: "workflow_stages"
            referencedColumns: ["id"]
          },
        ]
      }
      approval_delegations: {
        Row: {
          created_at: string
          delegate_user_id: string
          delegator_user_id: string
          ends_at: string
          id: string
          starts_at: string
          status: string
          tenant_id: string
          workflow_stage_id: string | null
        }
        Insert: {
          created_at?: string
          delegate_user_id: string
          delegator_user_id: string
          ends_at: string
          id?: string
          starts_at?: string
          status?: string
          tenant_id: string
          workflow_stage_id?: string | null
        }
        Update: {
          created_at?: string
          delegate_user_id?: string
          delegator_user_id?: string
          ends_at?: string
          id?: string
          starts_at?: string
          status?: string
          tenant_id?: string
          workflow_stage_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "approval_delegations_delegate_user_id_fkey"
            columns: ["delegate_user_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "approval_delegations_delegator_user_id_fkey"
            columns: ["delegator_user_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "approval_delegations_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "approval_delegations_workflow_stage_id_fkey"
            columns: ["workflow_stage_id"]
            isOneToOne: false
            referencedRelation: "workflow_stages"
            referencedColumns: ["id"]
          },
        ]
      }
      asset_assignments: {
        Row: {
          asset_id: string
          assigned_at: string
          assigned_by: string | null
          assigned_to: string
          id: string
          notes: string | null
          returned_at: string | null
          tenant_id: string
        }
        Insert: {
          asset_id: string
          assigned_at?: string
          assigned_by?: string | null
          assigned_to: string
          id?: string
          notes?: string | null
          returned_at?: string | null
          tenant_id: string
        }
        Update: {
          asset_id?: string
          assigned_at?: string
          assigned_by?: string | null
          assigned_to?: string
          id?: string
          notes?: string | null
          returned_at?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "asset_assignments_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "assets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "asset_assignments_assigned_by_fkey"
            columns: ["assigned_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "asset_assignments_assigned_to_fkey"
            columns: ["assigned_to"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "asset_assignments_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      asset_requests: {
        Row: {
          asset_type: string
          created_at: string
          decided_at: string | null
          decided_by: string | null
          decision_notes: string | null
          fulfilled_asset_id: string | null
          fulfilled_assignment_id: string | null
          id: string
          item_description: string
          justification: string | null
          requested_by: string
          status: string
          tenant_id: string
          updated_at: string
        }
        Insert: {
          asset_type: string
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          decision_notes?: string | null
          fulfilled_asset_id?: string | null
          fulfilled_assignment_id?: string | null
          id?: string
          item_description: string
          justification?: string | null
          requested_by: string
          status?: string
          tenant_id: string
          updated_at?: string
        }
        Update: {
          asset_type?: string
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          decision_notes?: string | null
          fulfilled_asset_id?: string | null
          fulfilled_assignment_id?: string | null
          id?: string
          item_description?: string
          justification?: string | null
          requested_by?: string
          status?: string
          tenant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "asset_requests_decided_by_fkey"
            columns: ["decided_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "asset_requests_fulfilled_asset_id_fkey"
            columns: ["fulfilled_asset_id"]
            isOneToOne: false
            referencedRelation: "assets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "asset_requests_fulfilled_assignment_id_fkey"
            columns: ["fulfilled_assignment_id"]
            isOneToOne: false
            referencedRelation: "asset_assignments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "asset_requests_requested_by_fkey"
            columns: ["requested_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "asset_requests_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      assets: {
        Row: {
          asset_tag: string | null
          category: string | null
          created_at: string
          id: string
          name: string
          notes: string | null
          purchase_cost: number | null
          purchase_date: string | null
          serial_number: string | null
          status: string
          tenant_id: string
          type: string
          updated_at: string
          vendor: string | null
        }
        Insert: {
          asset_tag?: string | null
          category?: string | null
          created_at?: string
          id?: string
          name: string
          notes?: string | null
          purchase_cost?: number | null
          purchase_date?: string | null
          serial_number?: string | null
          status?: string
          tenant_id: string
          type: string
          updated_at?: string
          vendor?: string | null
        }
        Update: {
          asset_tag?: string | null
          category?: string | null
          created_at?: string
          id?: string
          name?: string
          notes?: string | null
          purchase_cost?: number | null
          purchase_date?: string | null
          serial_number?: string | null
          status?: string
          tenant_id?: string
          type?: string
          updated_at?: string
          vendor?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "assets_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      bd_activities: {
        Row: {
          activity_date: string
          client_id: string | null
          created_at: string
          created_by: string | null
          description: string | null
          id: string
          subject: string
          tenant_id: string
          type: string
        }
        Insert: {
          activity_date?: string
          client_id?: string | null
          created_at?: string
          created_by?: string | null
          description?: string | null
          id?: string
          subject: string
          tenant_id: string
          type?: string
        }
        Update: {
          activity_date?: string
          client_id?: string | null
          created_at?: string
          created_by?: string | null
          description?: string | null
          id?: string
          subject?: string
          tenant_id?: string
          type?: string
        }
        Relationships: [
          {
            foreignKeyName: "bd_activities_client_id_fkey"
            columns: ["client_id"]
            isOneToOne: false
            referencedRelation: "bd_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bd_activities_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bd_activities_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      bd_client_categories: {
        Row: {
          created_at: string
          description: string | null
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        Insert: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
        }
        Update: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bd_client_categories_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      bd_clients: {
        Row: {
          category_id: string | null
          created_at: string
          created_by: string | null
          email: string | null
          id: string
          industry: string | null
          is_active: boolean
          name: string
          phone: string | null
          tenant_id: string
          updated_at: string
          website: string | null
        }
        Insert: {
          category_id?: string | null
          created_at?: string
          created_by?: string | null
          email?: string | null
          id?: string
          industry?: string | null
          is_active?: boolean
          name: string
          phone?: string | null
          tenant_id: string
          updated_at?: string
          website?: string | null
        }
        Update: {
          category_id?: string | null
          created_at?: string
          created_by?: string | null
          email?: string | null
          id?: string
          industry?: string | null
          is_active?: boolean
          name?: string
          phone?: string | null
          tenant_id?: string
          updated_at?: string
          website?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "bd_clients_category_id_fkey"
            columns: ["category_id"]
            isOneToOne: false
            referencedRelation: "bd_client_categories"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bd_clients_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bd_clients_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      bd_contacts: {
        Row: {
          client_id: string
          created_at: string
          email: string | null
          first_name: string
          id: string
          is_primary: boolean
          last_name: string
          phone: string | null
          position: string | null
          tenant_id: string
        }
        Insert: {
          client_id: string
          created_at?: string
          email?: string | null
          first_name: string
          id?: string
          is_primary?: boolean
          last_name: string
          phone?: string | null
          position?: string | null
          tenant_id: string
        }
        Update: {
          client_id?: string
          created_at?: string
          email?: string | null
          first_name?: string
          id?: string
          is_primary?: boolean
          last_name?: string
          phone?: string | null
          position?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bd_contacts_client_id_fkey"
            columns: ["client_id"]
            isOneToOne: false
            referencedRelation: "bd_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bd_contacts_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      bd_lead_sources: {
        Row: {
          created_at: string
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
        }
        Update: {
          created_at?: string
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bd_lead_sources_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      bd_lead_statuses: {
        Row: {
          color: string
          id: string
          is_active: boolean
          label: string
          order_index: number
          status: string
          tenant_id: string
        }
        Insert: {
          color?: string
          id?: string
          is_active?: boolean
          label: string
          order_index?: number
          status: string
          tenant_id: string
        }
        Update: {
          color?: string
          id?: string
          is_active?: boolean
          label?: string
          order_index?: number
          status?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bd_lead_statuses_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      bd_leads: {
        Row: {
          company_name: string
          contact_name: string
          converted_opportunity_id: string | null
          created_at: string
          created_by: string | null
          currency: string
          email: string | null
          estimated_value: number | null
          id: string
          lead_no: string | null
          notes: string | null
          phone: string | null
          source_id: string | null
          status: string
          tenant_id: string
          updated_at: string
        }
        Insert: {
          company_name: string
          contact_name: string
          converted_opportunity_id?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          email?: string | null
          estimated_value?: number | null
          id?: string
          lead_no?: string | null
          notes?: string | null
          phone?: string | null
          source_id?: string | null
          status?: string
          tenant_id: string
          updated_at?: string
        }
        Update: {
          company_name?: string
          contact_name?: string
          converted_opportunity_id?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          email?: string | null
          estimated_value?: number | null
          id?: string
          lead_no?: string | null
          notes?: string | null
          phone?: string | null
          source_id?: string | null
          status?: string
          tenant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "bd_leads_converted_opportunity_fk"
            columns: ["converted_opportunity_id"]
            isOneToOne: false
            referencedRelation: "bd_opportunities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bd_leads_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bd_leads_source_id_fkey"
            columns: ["source_id"]
            isOneToOne: false
            referencedRelation: "bd_lead_sources"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bd_leads_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      bd_opportunities: {
        Row: {
          client_id: string | null
          created_at: string
          created_by: string | null
          currency: string
          description: string | null
          estimated_value: number | null
          expected_close_date: string | null
          id: string
          lead_id: string | null
          lost_reason: string | null
          opportunity_no: string | null
          probability: number | null
          stage: string
          tenant_id: string
          title: string
          updated_at: string
        }
        Insert: {
          client_id?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          description?: string | null
          estimated_value?: number | null
          expected_close_date?: string | null
          id?: string
          lead_id?: string | null
          lost_reason?: string | null
          opportunity_no?: string | null
          probability?: number | null
          stage?: string
          tenant_id: string
          title: string
          updated_at?: string
        }
        Update: {
          client_id?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          description?: string | null
          estimated_value?: number | null
          expected_close_date?: string | null
          id?: string
          lead_id?: string | null
          lost_reason?: string | null
          opportunity_no?: string | null
          probability?: number | null
          stage?: string
          tenant_id?: string
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "bd_opportunities_client_id_fkey"
            columns: ["client_id"]
            isOneToOne: false
            referencedRelation: "bd_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bd_opportunities_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bd_opportunities_lead_id_fkey"
            columns: ["lead_id"]
            isOneToOne: false
            referencedRelation: "bd_leads"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bd_opportunities_tenant_id_stage_fkey"
            columns: ["tenant_id", "stage"]
            isOneToOne: false
            referencedRelation: "bd_opportunity_stages"
            referencedColumns: ["tenant_id", "stage"]
          },
        ]
      }
      bd_opportunity_stages: {
        Row: {
          color: string
          id: string
          is_active: boolean
          label: string
          order_index: number
          probability_default: number
          stage: string
          tenant_id: string
        }
        Insert: {
          color?: string
          id?: string
          is_active?: boolean
          label: string
          order_index?: number
          probability_default?: number
          stage: string
          tenant_id: string
        }
        Update: {
          color?: string
          id?: string
          is_active?: boolean
          label?: string
          order_index?: number
          probability_default?: number
          stage?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bd_opportunity_stages_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      bd_proposal_statuses: {
        Row: {
          color: string
          id: string
          is_active: boolean
          label: string
          order_index: number
          status: string
          tenant_id: string
        }
        Insert: {
          color?: string
          id?: string
          is_active?: boolean
          label: string
          order_index?: number
          status: string
          tenant_id: string
        }
        Update: {
          color?: string
          id?: string
          is_active?: boolean
          label?: string
          order_index?: number
          status?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bd_proposal_statuses_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      bd_proposal_templates: {
        Row: {
          content: string | null
          created_at: string
          description: string | null
          id: string
          is_active: boolean
          name: string
          tenant_id: string
          updated_at: string
        }
        Insert: {
          content?: string | null
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
          updated_at?: string
        }
        Update: {
          content?: string | null
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "bd_proposal_templates_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      bd_proposal_types: {
        Row: {
          created_at: string
          description: string | null
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        Insert: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
        }
        Update: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bd_proposal_types_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      bd_proposals: {
        Row: {
          client_id: string | null
          content: string | null
          created_at: string
          created_by: string | null
          currency: string
          decided_at: string | null
          decided_by: string | null
          decision_notes: string | null
          id: string
          opportunity_id: string | null
          proposal_no: string | null
          status: string
          tenant_id: string
          title: string
          total_value: number
          type_id: string | null
          updated_at: string
          valid_until: string | null
          version: number
        }
        Insert: {
          client_id?: string | null
          content?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          decided_at?: string | null
          decided_by?: string | null
          decision_notes?: string | null
          id?: string
          opportunity_id?: string | null
          proposal_no?: string | null
          status?: string
          tenant_id: string
          title: string
          total_value: number
          type_id?: string | null
          updated_at?: string
          valid_until?: string | null
          version?: number
        }
        Update: {
          client_id?: string | null
          content?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          decided_at?: string | null
          decided_by?: string | null
          decision_notes?: string | null
          id?: string
          opportunity_id?: string | null
          proposal_no?: string | null
          status?: string
          tenant_id?: string
          title?: string
          total_value?: number
          type_id?: string | null
          updated_at?: string
          valid_until?: string | null
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "bd_proposals_client_id_fkey"
            columns: ["client_id"]
            isOneToOne: false
            referencedRelation: "bd_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bd_proposals_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bd_proposals_decided_by_fkey"
            columns: ["decided_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bd_proposals_opportunity_id_fkey"
            columns: ["opportunity_id"]
            isOneToOne: false
            referencedRelation: "bd_opportunities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bd_proposals_tenant_id_status_fkey"
            columns: ["tenant_id", "status"]
            isOneToOne: false
            referencedRelation: "bd_proposal_statuses"
            referencedColumns: ["tenant_id", "status"]
          },
          {
            foreignKeyName: "bd_proposals_type_id_fkey"
            columns: ["type_id"]
            isOneToOne: false
            referencedRelation: "bd_proposal_types"
            referencedColumns: ["id"]
          },
        ]
      }
      bd_tender_types: {
        Row: {
          created_at: string
          description: string | null
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        Insert: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
        }
        Update: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bd_tender_types_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      bd_tenders: {
        Row: {
          client_id: string | null
          created_at: string
          created_by: string | null
          currency: string
          description: string | null
          estimated_value: number | null
          id: string
          portal_url: string | null
          status: string
          submission_deadline: string | null
          tenant_id: string
          tender_no: string | null
          title: string
          type_id: string | null
          updated_at: string
        }
        Insert: {
          client_id?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          description?: string | null
          estimated_value?: number | null
          id?: string
          portal_url?: string | null
          status?: string
          submission_deadline?: string | null
          tenant_id: string
          tender_no?: string | null
          title: string
          type_id?: string | null
          updated_at?: string
        }
        Update: {
          client_id?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          description?: string | null
          estimated_value?: number | null
          id?: string
          portal_url?: string | null
          status?: string
          submission_deadline?: string | null
          tenant_id?: string
          tender_no?: string | null
          title?: string
          type_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "bd_tenders_client_id_fkey"
            columns: ["client_id"]
            isOneToOne: false
            referencedRelation: "bd_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bd_tenders_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bd_tenders_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bd_tenders_type_id_fkey"
            columns: ["type_id"]
            isOneToOne: false
            referencedRelation: "bd_tender_types"
            referencedColumns: ["id"]
          },
        ]
      }
      cash_bank_transactions: {
        Row: {
          amount: number
          bank_account: string | null
          created_at: string
          currency: string
          description: string | null
          id: string
          payment_method: string
          recorded_by: string
          reference_id: string
          reference_type: string
          tenant_id: string
          transaction_date: string
          transaction_type: string
        }
        Insert: {
          amount: number
          bank_account?: string | null
          created_at?: string
          currency?: string
          description?: string | null
          id?: string
          payment_method: string
          recorded_by?: string
          reference_id: string
          reference_type: string
          tenant_id: string
          transaction_date: string
          transaction_type: string
        }
        Update: {
          amount?: number
          bank_account?: string | null
          created_at?: string
          currency?: string
          description?: string | null
          id?: string
          payment_method?: string
          recorded_by?: string
          reference_id?: string
          reference_type?: string
          tenant_id?: string
          transaction_date?: string
          transaction_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "cash_bank_transactions_recorded_by_fkey"
            columns: ["recorded_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cash_bank_transactions_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      cost_centers: {
        Row: {
          budget_amount: number | null
          created_at: string
          id: string
          name: string
          project_code: string | null
          tenant_id: string
        }
        Insert: {
          budget_amount?: number | null
          created_at?: string
          id?: string
          name: string
          project_code?: string | null
          tenant_id: string
        }
        Update: {
          budget_amount?: number | null
          created_at?: string
          id?: string
          name?: string
          project_code?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "cost_centers_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      departments: {
        Row: {
          created_at: string
          id: string
          is_active: boolean
          name: string
          parent_department_id: string | null
          tenant_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          is_active?: boolean
          name: string
          parent_department_id?: string | null
          tenant_id: string
        }
        Update: {
          created_at?: string
          id?: string
          is_active?: boolean
          name?: string
          parent_department_id?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "departments_parent_department_id_fkey"
            columns: ["parent_department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "departments_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      doc_sequences: {
        Row: {
          doc_type: string
          last_number: number
          tenant_id: string
          year: string
        }
        Insert: {
          doc_type: string
          last_number?: number
          tenant_id: string
          year: string
        }
        Update: {
          doc_type?: string
          last_number?: number
          tenant_id?: string
          year?: string
        }
        Relationships: [
          {
            foreignKeyName: "doc_sequences_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      expenditure_slips: {
        Row: {
          amount: number
          cost_center_id: string
          created_at: string
          currency: string
          id: string
          organization_id: string | null
          payee_name: string
          petty_cash_float_id: string | null
          purpose: string
          recorded_by: string
          slip_date: string
          slip_number: string
          tenant_id: string
          updated_at: string
        }
        Insert: {
          amount: number
          cost_center_id: string
          created_at?: string
          currency?: string
          id?: string
          organization_id?: string | null
          payee_name: string
          petty_cash_float_id?: string | null
          purpose: string
          recorded_by?: string
          slip_date: string
          slip_number: string
          tenant_id: string
          updated_at?: string
        }
        Update: {
          amount?: number
          cost_center_id?: string
          created_at?: string
          currency?: string
          id?: string
          organization_id?: string | null
          payee_name?: string
          petty_cash_float_id?: string | null
          purpose?: string
          recorded_by?: string
          slip_date?: string
          slip_number?: string
          tenant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "expenditure_slips_cost_center_id_fkey"
            columns: ["cost_center_id"]
            isOneToOne: false
            referencedRelation: "cost_centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenditure_slips_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenditure_slips_petty_cash_float_id_fkey"
            columns: ["petty_cash_float_id"]
            isOneToOne: false
            referencedRelation: "petty_cash_float_balances"
            referencedColumns: ["petty_cash_float_id"]
          },
          {
            foreignKeyName: "expenditure_slips_petty_cash_float_id_fkey"
            columns: ["petty_cash_float_id"]
            isOneToOne: false
            referencedRelation: "petty_cash_floats"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenditure_slips_recorded_by_fkey"
            columns: ["recorded_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenditure_slips_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      external_material_groups: {
        Row: {
          code: string
          created_at: string
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        Insert: {
          code: string
          created_at?: string
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
        }
        Update: {
          code?: string
          created_at?: string
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "external_material_groups_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      faqs: {
        Row: {
          answer: string
          category: string | null
          created_at: string
          id: string
          is_published: boolean
          question: string
          sort_order: number
          tenant_id: string
          updated_at: string
        }
        Insert: {
          answer: string
          category?: string | null
          created_at?: string
          id?: string
          is_published?: boolean
          question: string
          sort_order?: number
          tenant_id: string
          updated_at?: string
        }
        Update: {
          answer?: string
          category?: string | null
          created_at?: string
          id?: string
          is_published?: boolean
          question?: string
          sort_order?: number
          tenant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "faqs_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      finance_team_members: {
        Row: {
          created_at: string
          id: string
          role: string
          tenant_id: string
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          role: string
          tenant_id: string
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          role?: string
          tenant_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "finance_team_members_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "finance_team_members_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
        ]
      }
      fuel_logs: {
        Row: {
          cost: number | null
          created_at: string
          fuel_liters: number
          id: string
          log_date: string
          machine_id: string
          notes: string | null
          tenant_id: string
        }
        Insert: {
          cost?: number | null
          created_at?: string
          fuel_liters: number
          id?: string
          log_date: string
          machine_id: string
          notes?: string | null
          tenant_id: string
        }
        Update: {
          cost?: number | null
          created_at?: string
          fuel_liters?: number
          id?: string
          log_date?: string
          machine_id?: string
          notes?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fuel_logs_machine_id_fkey"
            columns: ["machine_id"]
            isOneToOne: false
            referencedRelation: "machines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fuel_logs_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      goods_issue_items: {
        Row: {
          cost_center_id: string | null
          delivered_qty: number
          goods_issue_id: string
          id: string
          item_no: number
          material_catalog_id: string | null
          material_description: string
          remarks: string | null
          requested_qty: number | null
          unit: string
        }
        Insert: {
          cost_center_id?: string | null
          delivered_qty: number
          goods_issue_id: string
          id?: string
          item_no: number
          material_catalog_id?: string | null
          material_description: string
          remarks?: string | null
          requested_qty?: number | null
          unit: string
        }
        Update: {
          cost_center_id?: string | null
          delivered_qty?: number
          goods_issue_id?: string
          id?: string
          item_no?: number
          material_catalog_id?: string | null
          material_description?: string
          remarks?: string | null
          requested_qty?: number | null
          unit?: string
        }
        Relationships: [
          {
            foreignKeyName: "goods_issue_items_cost_center_id_fkey"
            columns: ["cost_center_id"]
            isOneToOne: false
            referencedRelation: "cost_centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "goods_issue_items_goods_issue_id_fkey"
            columns: ["goods_issue_id"]
            isOneToOne: false
            referencedRelation: "goods_issues"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "goods_issue_items_material_catalog_id_fkey"
            columns: ["material_catalog_id"]
            isOneToOne: false
            referencedRelation: "material_catalog"
            referencedColumns: ["id"]
          },
        ]
      }
      goods_issues: {
        Row: {
          approved_by_name: string | null
          created_at: string
          id: string
          issue_date: string
          project_label: string | null
          received_by_name: string | null
          tenant_id: string
          voucher_no: string | null
          warehouse_id: string
          warehouse_officer_id: string
        }
        Insert: {
          approved_by_name?: string | null
          created_at?: string
          id?: string
          issue_date?: string
          project_label?: string | null
          received_by_name?: string | null
          tenant_id: string
          voucher_no?: string | null
          warehouse_id: string
          warehouse_officer_id: string
        }
        Update: {
          approved_by_name?: string | null
          created_at?: string
          id?: string
          issue_date?: string
          project_label?: string | null
          received_by_name?: string | null
          tenant_id?: string
          voucher_no?: string | null
          warehouse_id?: string
          warehouse_officer_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "goods_issues_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "goods_issues_warehouse_id_fkey"
            columns: ["warehouse_id"]
            isOneToOne: false
            referencedRelation: "warehouses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "goods_issues_warehouse_officer_id_fkey"
            columns: ["warehouse_officer_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
        ]
      }
      hr_appraisals: {
        Row: {
          comments: string | null
          created_at: string
          created_by: string | null
          employee_id: string
          id: string
          period: string
          rating: number | null
          status: string
          tenant_id: string
          updated_at: string
        }
        Insert: {
          comments?: string | null
          created_at?: string
          created_by?: string | null
          employee_id: string
          id?: string
          period: string
          rating?: number | null
          status?: string
          tenant_id: string
          updated_at?: string
        }
        Update: {
          comments?: string | null
          created_at?: string
          created_by?: string | null
          employee_id?: string
          id?: string
          period?: string
          rating?: number | null
          status?: string
          tenant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "hr_appraisals_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_appraisals_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "hr_employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_appraisals_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      hr_attendance: {
        Row: {
          attendance_date: string
          check_in: string | null
          check_out: string | null
          created_at: string
          employee_id: string
          id: string
          notes: string | null
          status: string
          tenant_id: string
        }
        Insert: {
          attendance_date: string
          check_in?: string | null
          check_out?: string | null
          created_at?: string
          employee_id: string
          id?: string
          notes?: string | null
          status?: string
          tenant_id: string
        }
        Update: {
          attendance_date?: string
          check_in?: string | null
          check_out?: string | null
          created_at?: string
          employee_id?: string
          id?: string
          notes?: string | null
          status?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "hr_attendance_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "hr_employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_attendance_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      hr_employee_compensation: {
        Row: {
          basic_salary: number
          contract_reference: string | null
          created_at: string
          created_by: string
          currency: string
          effective_date: string
          employee_id: string
          id: string
          note: string | null
          tenant_id: string
        }
        Insert: {
          basic_salary: number
          contract_reference?: string | null
          created_at?: string
          created_by: string
          currency?: string
          effective_date: string
          employee_id: string
          id?: string
          note?: string | null
          tenant_id: string
        }
        Update: {
          basic_salary?: number
          contract_reference?: string | null
          created_at?: string
          created_by?: string
          currency?: string
          effective_date?: string
          employee_id?: string
          id?: string
          note?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "hr_employee_compensation_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_employee_compensation_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "hr_employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_employee_compensation_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      hr_employees: {
        Row: {
          created_at: string
          department_id: string | null
          email: string
          employee_no: string
          employment_status: string
          first_name: string
          hire_date: string | null
          id: string
          is_active: boolean
          last_name: string
          manager_id: string | null
          phone: string | null
          position_id: string | null
          tenant_id: string
          updated_at: string
          user_id: string | null
        }
        Insert: {
          created_at?: string
          department_id?: string | null
          email: string
          employee_no: string
          employment_status?: string
          first_name: string
          hire_date?: string | null
          id?: string
          is_active?: boolean
          last_name: string
          manager_id?: string | null
          phone?: string | null
          position_id?: string | null
          tenant_id: string
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          created_at?: string
          department_id?: string | null
          email?: string
          employee_no?: string
          employment_status?: string
          first_name?: string
          hire_date?: string | null
          id?: string
          is_active?: boolean
          last_name?: string
          manager_id?: string | null
          phone?: string | null
          position_id?: string | null
          tenant_id?: string
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "hr_employees_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "hr_employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_employees_position_id_fkey"
            columns: ["position_id"]
            isOneToOne: false
            referencedRelation: "hr_positions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_employees_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_employees_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
        ]
      }
      hr_job_applications: {
        Row: {
          candidate_name: string
          created_at: string
          email: string | null
          id: string
          job_posting_id: string | null
          phone: string | null
          stage: string
          tenant_id: string
        }
        Insert: {
          candidate_name: string
          created_at?: string
          email?: string | null
          id?: string
          job_posting_id?: string | null
          phone?: string | null
          stage?: string
          tenant_id: string
        }
        Update: {
          candidate_name?: string
          created_at?: string
          email?: string | null
          id?: string
          job_posting_id?: string | null
          phone?: string | null
          stage?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "hr_job_applications_job_posting_id_fkey"
            columns: ["job_posting_id"]
            isOneToOne: false
            referencedRelation: "hr_job_postings"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_job_applications_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      hr_job_postings: {
        Row: {
          created_at: string
          department_id: string | null
          description: string | null
          id: string
          position_id: string | null
          status: string
          tenant_id: string
          title: string
        }
        Insert: {
          created_at?: string
          department_id?: string | null
          description?: string | null
          id?: string
          position_id?: string | null
          status?: string
          tenant_id: string
          title: string
        }
        Update: {
          created_at?: string
          department_id?: string | null
          description?: string | null
          id?: string
          position_id?: string | null
          status?: string
          tenant_id?: string
          title?: string
        }
        Relationships: [
          {
            foreignKeyName: "hr_job_postings_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_job_postings_position_id_fkey"
            columns: ["position_id"]
            isOneToOne: false
            referencedRelation: "hr_positions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_job_postings_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      hr_leave_requests: {
        Row: {
          approver_id: string | null
          created_at: string
          days: number
          employee_id: string
          end_date: string
          id: string
          leave_no: string
          leave_type_id: string
          reason: string | null
          start_date: string
          status: string
          tenant_id: string
          updated_at: string
        }
        Insert: {
          approver_id?: string | null
          created_at?: string
          days: number
          employee_id: string
          end_date: string
          id?: string
          leave_no: string
          leave_type_id: string
          reason?: string | null
          start_date: string
          status?: string
          tenant_id: string
          updated_at?: string
        }
        Update: {
          approver_id?: string | null
          created_at?: string
          days?: number
          employee_id?: string
          end_date?: string
          id?: string
          leave_no?: string
          leave_type_id?: string
          reason?: string | null
          start_date?: string
          status?: string
          tenant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "hr_leave_requests_approver_id_fkey"
            columns: ["approver_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "hr_employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_leave_requests_leave_type_id_fkey"
            columns: ["leave_type_id"]
            isOneToOne: false
            referencedRelation: "hr_leave_types"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_leave_requests_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      hr_leave_types: {
        Row: {
          created_at: string
          days_per_year: number
          description: string | null
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        Insert: {
          created_at?: string
          days_per_year?: number
          description?: string | null
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
        }
        Update: {
          created_at?: string
          days_per_year?: number
          description?: string | null
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "hr_leave_types_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      hr_payroll_items: {
        Row: {
          allowances: number
          basic_salary: number
          deductions: number
          employee_id: string
          id: string
          net_pay: number | null
          note: string | null
          payroll_run_id: string
        }
        Insert: {
          allowances?: number
          basic_salary: number
          deductions?: number
          employee_id: string
          id?: string
          net_pay?: number | null
          note?: string | null
          payroll_run_id: string
        }
        Update: {
          allowances?: number
          basic_salary?: number
          deductions?: number
          employee_id?: string
          id?: string
          net_pay?: number | null
          note?: string | null
          payroll_run_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "hr_payroll_items_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "hr_employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_payroll_items_payroll_run_id_fkey"
            columns: ["payroll_run_id"]
            isOneToOne: false
            referencedRelation: "hr_payroll_runs"
            referencedColumns: ["id"]
          },
        ]
      }
      hr_payroll_runs: {
        Row: {
          amount_disbursed: number
          approved_at: string | null
          approved_by: string | null
          created_at: string
          id: string
          period: string
          prepared_by: string
          rejected_at: string | null
          rejected_by: string | null
          rejection_reason: string | null
          status: string
          submitted_at: string | null
          tenant_id: string
        }
        Insert: {
          amount_disbursed?: number
          approved_at?: string | null
          approved_by?: string | null
          created_at?: string
          id?: string
          period: string
          prepared_by: string
          rejected_at?: string | null
          rejected_by?: string | null
          rejection_reason?: string | null
          status?: string
          submitted_at?: string | null
          tenant_id: string
        }
        Update: {
          amount_disbursed?: number
          approved_at?: string | null
          approved_by?: string | null
          created_at?: string
          id?: string
          period?: string
          prepared_by?: string
          rejected_at?: string | null
          rejected_by?: string | null
          rejection_reason?: string | null
          status?: string
          submitted_at?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "hr_payroll_runs_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_payroll_runs_prepared_by_fkey"
            columns: ["prepared_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_payroll_runs_rejected_by_fkey"
            columns: ["rejected_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_payroll_runs_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      hr_positions: {
        Row: {
          created_at: string
          description: string | null
          id: string
          is_active: boolean
          tenant_id: string
          title: string
        }
        Insert: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          tenant_id: string
          title: string
        }
        Update: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          tenant_id?: string
          title?: string
        }
        Relationships: [
          {
            foreignKeyName: "hr_positions_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      hr_team_members: {
        Row: {
          created_at: string
          id: string
          role: string
          tenant_id: string
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          role: string
          tenant_id: string
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          role?: string
          tenant_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "hr_team_members_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_team_members_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
        ]
      }
      hr_trainings: {
        Row: {
          created_at: string
          created_by: string | null
          description: string | null
          end_date: string | null
          id: string
          provider: string | null
          start_date: string | null
          status: string
          tenant_id: string
          title: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          description?: string | null
          end_date?: string | null
          id?: string
          provider?: string | null
          start_date?: string | null
          status?: string
          tenant_id: string
          title: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          description?: string | null
          end_date?: string | null
          id?: string
          provider?: string | null
          start_date?: string | null
          status?: string
          tenant_id?: string
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "hr_trainings_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_trainings_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      impersonation_logs: {
        Row: {
          action: string
          id: string
          logged_at: string
          platform_admin_email: string | null
          platform_admin_id: string
          tenant_id: string | null
        }
        Insert: {
          action: string
          id?: string
          logged_at?: string
          platform_admin_email?: string | null
          platform_admin_id: string
          tenant_id?: string | null
        }
        Update: {
          action?: string
          id?: string
          logged_at?: string
          platform_admin_email?: string | null
          platform_admin_id?: string
          tenant_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "impersonation_logs_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      impersonation_sessions: {
        Row: {
          ended_at: string | null
          id: string
          platform_admin_id: string
          started_at: string
          tenant_id: string
        }
        Insert: {
          ended_at?: string | null
          id?: string
          platform_admin_id: string
          started_at?: string
          tenant_id: string
        }
        Update: {
          ended_at?: string | null
          id?: string
          platform_admin_id?: string
          started_at?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "impersonation_sessions_platform_admin_id_fkey"
            columns: ["platform_admin_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "impersonation_sessions_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      invitations: {
        Row: {
          accepted_at: string | null
          created_at: string
          email: string
          finance_role: string | null
          id: string
          invited_by: string
          modules_and_roles: Json | null
          role_bundle: string
          status: string
          tenant_id: string
        }
        Insert: {
          accepted_at?: string | null
          created_at?: string
          email: string
          finance_role?: string | null
          id?: string
          invited_by: string
          modules_and_roles?: Json | null
          role_bundle?: string
          status?: string
          tenant_id: string
        }
        Update: {
          accepted_at?: string | null
          created_at?: string
          email?: string
          finance_role?: string | null
          id?: string
          invited_by?: string
          modules_and_roles?: Json | null
          role_bundle?: string
          status?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "invitations_invited_by_fkey"
            columns: ["invited_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invitations_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      invoice_requests: {
        Row: {
          amount: number
          cost_center_id: string | null
          created_at: string | null
          current_stage_id: string | null
          department_id: string | null
          description: string | null
          id: string
          requester_id: string
          status: string
          tenant_id: string
          updated_at: string | null
          vendor_name: string | null
        }
        Insert: {
          amount?: number
          cost_center_id?: string | null
          created_at?: string | null
          current_stage_id?: string | null
          department_id?: string | null
          description?: string | null
          id?: string
          requester_id: string
          status?: string
          tenant_id: string
          updated_at?: string | null
          vendor_name?: string | null
        }
        Update: {
          amount?: number
          cost_center_id?: string | null
          created_at?: string | null
          current_stage_id?: string | null
          department_id?: string | null
          description?: string | null
          id?: string
          requester_id?: string
          status?: string
          tenant_id?: string
          updated_at?: string | null
          vendor_name?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "invoice_requests_cost_center_id_fkey"
            columns: ["cost_center_id"]
            isOneToOne: false
            referencedRelation: "cost_centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_requests_current_stage_id_fkey"
            columns: ["current_stage_id"]
            isOneToOne: false
            referencedRelation: "workflow_stages"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_requests_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_requests_requester_id_fkey"
            columns: ["requester_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_requests_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      it_tickets: {
        Row: {
          approval_notes: string | null
          approval_status: string
          approved_at: string | null
          approved_by: string | null
          assignee_id: string | null
          category: string
          closed_at: string | null
          created_at: string
          department_id: string
          description: string
          id: string
          priority: string
          requester_id: string
          requires_approval: boolean
          resolution_notes: string | null
          resolved_at: string | null
          status: string
          subject: string
          tenant_id: string
          ticket_number: string
          updated_at: string
        }
        Insert: {
          approval_notes?: string | null
          approval_status?: string
          approved_at?: string | null
          approved_by?: string | null
          assignee_id?: string | null
          category: string
          closed_at?: string | null
          created_at?: string
          department_id: string
          description: string
          id?: string
          priority?: string
          requester_id: string
          requires_approval?: boolean
          resolution_notes?: string | null
          resolved_at?: string | null
          status?: string
          subject: string
          tenant_id: string
          ticket_number: string
          updated_at?: string
        }
        Update: {
          approval_notes?: string | null
          approval_status?: string
          approved_at?: string | null
          approved_by?: string | null
          assignee_id?: string | null
          category?: string
          closed_at?: string | null
          created_at?: string
          department_id?: string
          description?: string
          id?: string
          priority?: string
          requester_id?: string
          requires_approval?: boolean
          resolution_notes?: string | null
          resolved_at?: string | null
          status?: string
          subject?: string
          tenant_id?: string
          ticket_number?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "it_tickets_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "it_tickets_assignee_id_fkey"
            columns: ["assignee_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "it_tickets_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "it_tickets_requester_id_fkey"
            columns: ["requester_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "it_tickets_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      kb_articles: {
        Row: {
          category: string | null
          content: string
          created_at: string
          created_by: string | null
          id: string
          is_published: boolean
          tenant_id: string
          title: string
          updated_at: string
        }
        Insert: {
          category?: string | null
          content: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_published?: boolean
          tenant_id: string
          title: string
          updated_at?: string
        }
        Update: {
          category?: string | null
          content?: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_published?: boolean
          tenant_id?: string
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "kb_articles_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "kb_articles_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      law_case_hearings: {
        Row: {
          case_id: string
          created_at: string
          created_by: string | null
          hearing_date: string
          id: string
          location: string | null
          notes: string | null
          outcome: string | null
          tenant_id: string
        }
        Insert: {
          case_id: string
          created_at?: string
          created_by?: string | null
          hearing_date: string
          id?: string
          location?: string | null
          notes?: string | null
          outcome?: string | null
          tenant_id: string
        }
        Update: {
          case_id?: string
          created_at?: string
          created_by?: string | null
          hearing_date?: string
          id?: string
          location?: string | null
          notes?: string | null
          outcome?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "law_case_hearings_case_id_fkey"
            columns: ["case_id"]
            isOneToOne: false
            referencedRelation: "law_cases"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "law_case_hearings_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "law_case_hearings_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      law_case_types: {
        Row: {
          created_at: string
          description: string | null
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        Insert: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
        }
        Update: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "law_case_types_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      law_cases: {
        Row: {
          case_no: string
          created_at: string
          created_by: string | null
          description: string | null
          id: string
          lawyer_name: string | null
          status: string
          tenant_id: string
          title: string
          type_id: string | null
          updated_at: string
        }
        Insert: {
          case_no: string
          created_at?: string
          created_by?: string | null
          description?: string | null
          id?: string
          lawyer_name?: string | null
          status?: string
          tenant_id: string
          title: string
          type_id?: string | null
          updated_at?: string
        }
        Update: {
          case_no?: string
          created_at?: string
          created_by?: string | null
          description?: string | null
          id?: string
          lawyer_name?: string | null
          status?: string
          tenant_id?: string
          title?: string
          type_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "law_cases_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "law_cases_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "law_cases_type_id_fkey"
            columns: ["type_id"]
            isOneToOne: false
            referencedRelation: "law_case_types"
            referencedColumns: ["id"]
          },
        ]
      }
      law_compliance_register: {
        Row: {
          created_at: string
          created_by: string
          due_date: string | null
          id: string
          item_no: string
          owner_id: string | null
          regulation: string | null
          status: string
          tenant_id: string
          title: string
        }
        Insert: {
          created_at?: string
          created_by?: string
          due_date?: string | null
          id?: string
          item_no: string
          owner_id?: string | null
          regulation?: string | null
          status?: string
          tenant_id: string
          title: string
        }
        Update: {
          created_at?: string
          created_by?: string
          due_date?: string | null
          id?: string
          item_no?: string
          owner_id?: string | null
          regulation?: string | null
          status?: string
          tenant_id?: string
          title?: string
        }
        Relationships: [
          {
            foreignKeyName: "law_compliance_register_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "law_compliance_register_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "law_compliance_register_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      law_contract_types: {
        Row: {
          created_at: string
          description: string | null
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        Insert: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
        }
        Update: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "law_contract_types_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      law_contracts: {
        Row: {
          contract_no: string
          created_at: string
          created_by: string | null
          currency: string
          end_date: string | null
          id: string
          party_name: string
          start_date: string | null
          status: string
          tenant_id: string
          title: string
          type_id: string | null
          updated_at: string
          value: number | null
        }
        Insert: {
          contract_no: string
          created_at?: string
          created_by?: string | null
          currency?: string
          end_date?: string | null
          id?: string
          party_name: string
          start_date?: string | null
          status?: string
          tenant_id: string
          title: string
          type_id?: string | null
          updated_at?: string
          value?: number | null
        }
        Update: {
          contract_no?: string
          created_at?: string
          created_by?: string | null
          currency?: string
          end_date?: string | null
          id?: string
          party_name?: string
          start_date?: string | null
          status?: string
          tenant_id?: string
          title?: string
          type_id?: string | null
          updated_at?: string
          value?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "law_contracts_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "law_contracts_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "law_contracts_type_id_fkey"
            columns: ["type_id"]
            isOneToOne: false
            referencedRelation: "law_contract_types"
            referencedColumns: ["id"]
          },
        ]
      }
      law_regulatory_filings: {
        Row: {
          created_at: string
          created_by: string | null
          filing_date: string | null
          filing_type: string | null
          id: string
          reference_no: string | null
          status: string
          tenant_id: string
          title: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          filing_date?: string | null
          filing_type?: string | null
          id?: string
          reference_no?: string | null
          status?: string
          tenant_id: string
          title: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          filing_date?: string | null
          filing_type?: string | null
          id?: string
          reference_no?: string | null
          status?: string
          tenant_id?: string
          title?: string
        }
        Relationships: [
          {
            foreignKeyName: "law_regulatory_filings_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "law_regulatory_filings_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      licenses: {
        Row: {
          asset_id: string
          created_at: string
          expiry_date: string | null
          id: string
          license_key: string | null
          notes: string | null
          seats_total: number
          tenant_id: string
          updated_at: string
          vendor: string | null
        }
        Insert: {
          asset_id: string
          created_at?: string
          expiry_date?: string | null
          id?: string
          license_key?: string | null
          notes?: string | null
          seats_total?: number
          tenant_id: string
          updated_at?: string
          vendor?: string | null
        }
        Update: {
          asset_id?: string
          created_at?: string
          expiry_date?: string | null
          id?: string
          license_key?: string | null
          notes?: string | null
          seats_total?: number
          tenant_id?: string
          updated_at?: string
          vendor?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "licenses_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "assets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "licenses_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      line_item_receipts: {
        Row: {
          approved_at: string | null
          approved_by: string | null
          id: string
          line_item_id: string
          note: string | null
          received_at: string
          received_by: string
          received_qty: number
          voucher_no: string | null
          warehouse_id: string | null
        }
        Insert: {
          approved_at?: string | null
          approved_by?: string | null
          id?: string
          line_item_id: string
          note?: string | null
          received_at?: string
          received_by: string
          received_qty: number
          voucher_no?: string | null
          warehouse_id?: string | null
        }
        Update: {
          approved_at?: string | null
          approved_by?: string | null
          id?: string
          line_item_id?: string
          note?: string | null
          received_at?: string
          received_by?: string
          received_qty?: number
          voucher_no?: string | null
          warehouse_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "line_item_receipts_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "line_item_receipts_line_item_id_fkey"
            columns: ["line_item_id"]
            isOneToOne: false
            referencedRelation: "line_item_receipt_status"
            referencedColumns: ["line_item_id"]
          },
          {
            foreignKeyName: "line_item_receipts_line_item_id_fkey"
            columns: ["line_item_id"]
            isOneToOne: false
            referencedRelation: "request_line_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "line_item_receipts_received_by_fkey"
            columns: ["received_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "line_item_receipts_warehouse_id_fkey"
            columns: ["warehouse_id"]
            isOneToOne: false
            referencedRelation: "warehouses"
            referencedColumns: ["id"]
          },
        ]
      }
      machine_assignments: {
        Row: {
          created_at: string
          end_date: string | null
          id: string
          machine_id: string
          operator_name: string | null
          project_name: string | null
          start_date: string | null
          status: string
          tenant_id: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          end_date?: string | null
          id?: string
          machine_id: string
          operator_name?: string | null
          project_name?: string | null
          start_date?: string | null
          status?: string
          tenant_id: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          end_date?: string | null
          id?: string
          machine_id?: string
          operator_name?: string | null
          project_name?: string | null
          start_date?: string | null
          status?: string
          tenant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "machine_assignments_machine_id_fkey"
            columns: ["machine_id"]
            isOneToOne: false
            referencedRelation: "machines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "machine_assignments_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      machine_types: {
        Row: {
          created_at: string
          description: string | null
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        Insert: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
        }
        Update: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "machine_types_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      machines: {
        Row: {
          created_at: string
          id: string
          location: string | null
          machine_no: string
          model: string | null
          name: string
          purchase_date: string | null
          serial_number: string | null
          status: string
          tenant_id: string
          type_id: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          id?: string
          location?: string | null
          machine_no: string
          model?: string | null
          name: string
          purchase_date?: string | null
          serial_number?: string | null
          status?: string
          tenant_id: string
          type_id?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          id?: string
          location?: string | null
          machine_no?: string
          model?: string | null
          name?: string
          purchase_date?: string | null
          serial_number?: string | null
          status?: string
          tenant_id?: string
          type_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "machines_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "machines_type_id_fkey"
            columns: ["type_id"]
            isOneToOne: false
            referencedRelation: "machine_types"
            referencedColumns: ["id"]
          },
        ]
      }
      maintenance_requests: {
        Row: {
          completed_date: string | null
          created_at: string
          description: string
          id: string
          machine_id: string
          requested_by: string | null
          scheduled_date: string | null
          status: string
          tenant_id: string
          type: string
          updated_at: string
        }
        Insert: {
          completed_date?: string | null
          created_at?: string
          description: string
          id?: string
          machine_id: string
          requested_by?: string | null
          scheduled_date?: string | null
          status?: string
          tenant_id: string
          type: string
          updated_at?: string
        }
        Update: {
          completed_date?: string | null
          created_at?: string
          description?: string
          id?: string
          machine_id?: string
          requested_by?: string | null
          scheduled_date?: string | null
          status?: string
          tenant_id?: string
          type?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "maintenance_requests_machine_id_fkey"
            columns: ["machine_id"]
            isOneToOne: false
            referencedRelation: "machines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "maintenance_requests_requested_by_fkey"
            columns: ["requested_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "maintenance_requests_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      maintenance_types: {
        Row: {
          created_at: string
          description: string | null
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        Insert: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
        }
        Update: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "maintenance_types_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      material_catalog: {
        Row: {
          code: string | null
          created_at: string | null
          description_en: string | null
          description_fr: string | null
          description_tr: string | null
          external_material_group_id: string | null
          id: string
          is_active: boolean
          material_group_id: string | null
          material_type_id: string | null
          name: string
          old_material_code: string | null
          tenant_id: string
          unit: string | null
        }
        Insert: {
          code?: string | null
          created_at?: string | null
          description_en?: string | null
          description_fr?: string | null
          description_tr?: string | null
          external_material_group_id?: string | null
          id?: string
          is_active?: boolean
          material_group_id?: string | null
          material_type_id?: string | null
          name: string
          old_material_code?: string | null
          tenant_id: string
          unit?: string | null
        }
        Update: {
          code?: string | null
          created_at?: string | null
          description_en?: string | null
          description_fr?: string | null
          description_tr?: string | null
          external_material_group_id?: string | null
          id?: string
          is_active?: boolean
          material_group_id?: string | null
          material_type_id?: string | null
          name?: string
          old_material_code?: string | null
          tenant_id?: string
          unit?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "material_catalog_external_material_group_id_fkey"
            columns: ["external_material_group_id"]
            isOneToOne: false
            referencedRelation: "external_material_groups"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "material_catalog_material_group_id_fkey"
            columns: ["material_group_id"]
            isOneToOne: false
            referencedRelation: "material_groups"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "material_catalog_material_type_id_fkey"
            columns: ["material_type_id"]
            isOneToOne: false
            referencedRelation: "material_types"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "material_catalog_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      material_groups: {
        Row: {
          code: string
          created_at: string
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        Insert: {
          code: string
          created_at?: string
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
        }
        Update: {
          code?: string
          created_at?: string
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "material_groups_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      material_receipt_assignments: {
        Row: {
          assigned_by: string
          created_at: string
          id: string
          tenant_id: string
          user_id: string
        }
        Insert: {
          assigned_by: string
          created_at?: string
          id?: string
          tenant_id: string
          user_id: string
        }
        Update: {
          assigned_by?: string
          created_at?: string
          id?: string
          tenant_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "material_receipt_assignments_assigned_by_fkey"
            columns: ["assigned_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "material_receipt_assignments_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "material_receipt_assignments_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
        ]
      }
      material_request_batches: {
        Row: {
          created_at: string | null
          id: string
          requester_id: string
          tenant_id: string
          updated_at: string | null
        }
        Insert: {
          created_at?: string | null
          id?: string
          requester_id: string
          tenant_id: string
          updated_at?: string | null
        }
        Update: {
          created_at?: string | null
          id?: string
          requester_id?: string
          tenant_id?: string
          updated_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "material_requests_requester_id_fkey"
            columns: ["requester_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "material_requests_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      material_request_items: {
        Row: {
          batch_id: string
          created_at: string
          decided_at: string | null
          decided_by: string | null
          description_en: string | null
          description_fr: string | null
          description_tr: string | null
          external_material_group_id: string | null
          id: string
          material_catalog_id: string | null
          material_group_id: string | null
          material_type_id: string | null
          name: string
          old_material_code: string | null
          rejection_message: string | null
          status: string
          tenant_id: string
          unit: string | null
        }
        Insert: {
          batch_id: string
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          description_en?: string | null
          description_fr?: string | null
          description_tr?: string | null
          external_material_group_id?: string | null
          id?: string
          material_catalog_id?: string | null
          material_group_id?: string | null
          material_type_id?: string | null
          name: string
          old_material_code?: string | null
          rejection_message?: string | null
          status?: string
          tenant_id: string
          unit?: string | null
        }
        Update: {
          batch_id?: string
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          description_en?: string | null
          description_fr?: string | null
          description_tr?: string | null
          external_material_group_id?: string | null
          id?: string
          material_catalog_id?: string | null
          material_group_id?: string | null
          material_type_id?: string | null
          name?: string
          old_material_code?: string | null
          rejection_message?: string | null
          status?: string
          tenant_id?: string
          unit?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "material_request_items_batch_id_fkey"
            columns: ["batch_id"]
            isOneToOne: false
            referencedRelation: "material_request_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "material_request_items_decided_by_fkey"
            columns: ["decided_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "material_request_items_external_material_group_id_fkey"
            columns: ["external_material_group_id"]
            isOneToOne: false
            referencedRelation: "external_material_groups"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "material_request_items_material_catalog_id_fkey"
            columns: ["material_catalog_id"]
            isOneToOne: false
            referencedRelation: "material_catalog"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "material_request_items_material_group_id_fkey"
            columns: ["material_group_id"]
            isOneToOne: false
            referencedRelation: "material_groups"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "material_request_items_material_type_id_fkey"
            columns: ["material_type_id"]
            isOneToOne: false
            referencedRelation: "material_types"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "material_request_items_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      material_types: {
        Row: {
          code: string
          created_at: string
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        Insert: {
          code: string
          created_at?: string
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
        }
        Update: {
          code?: string
          created_at?: string
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "material_types_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      notifications: {
        Row: {
          body: string
          created_at: string
          id: string
          invoice_request_id: string | null
          purchase_order_id: string | null
          read_at: string | null
          recipient_id: string
          request_id: string | null
          tenant_id: string
          title: string
          type: string
        }
        Insert: {
          body: string
          created_at?: string
          id?: string
          invoice_request_id?: string | null
          purchase_order_id?: string | null
          read_at?: string | null
          recipient_id: string
          request_id?: string | null
          tenant_id: string
          title: string
          type: string
        }
        Update: {
          body?: string
          created_at?: string
          id?: string
          invoice_request_id?: string | null
          purchase_order_id?: string | null
          read_at?: string | null
          recipient_id?: string
          request_id?: string | null
          tenant_id?: string
          title?: string
          type?: string
        }
        Relationships: [
          {
            foreignKeyName: "notifications_invoice_request_id_fkey"
            columns: ["invoice_request_id"]
            isOneToOne: false
            referencedRelation: "invoice_requests"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "v_request_tracking"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "notifications_recipient_id_fkey"
            columns: ["recipient_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_request_id_fkey"
            columns: ["request_id"]
            isOneToOne: false
            referencedRelation: "requests"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_request_id_fkey"
            columns: ["request_id"]
            isOneToOne: false
            referencedRelation: "v_request_tracking"
            referencedColumns: ["request_id"]
          },
          {
            foreignKeyName: "notifications_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      oif_sequences: {
        Row: {
          invoice_type: string
          last_number: number
          organization_id: string
        }
        Insert: {
          invoice_type: string
          last_number?: number
          organization_id: string
        }
        Update: {
          invoice_type?: string
          last_number?: number
          organization_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "oif_sequences_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      operation_logs: {
        Row: {
          created_at: string
          hours_used: number
          id: string
          log_date: string
          machine_id: string
          operator_name: string | null
          tenant_id: string
          work_description: string | null
        }
        Insert: {
          created_at?: string
          hours_used: number
          id?: string
          log_date: string
          machine_id: string
          operator_name?: string | null
          tenant_id: string
          work_description?: string | null
        }
        Update: {
          created_at?: string
          hours_used?: number
          id?: string
          log_date?: string
          machine_id?: string
          operator_name?: string | null
          tenant_id?: string
          work_description?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "operation_logs_machine_id_fkey"
            columns: ["machine_id"]
            isOneToOne: false
            referencedRelation: "machines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "operation_logs_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      organizations: {
        Row: {
          company_code: string
          created_at: string
          id: string
          is_active: boolean
          site_name: string
          tenant_id: string
        }
        Insert: {
          company_code: string
          created_at?: string
          id?: string
          is_active?: boolean
          site_name: string
          tenant_id: string
        }
        Update: {
          company_code?: string
          created_at?: string
          id?: string
          is_active?: boolean
          site_name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "organizations_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      payroll_approvers: {
        Row: {
          created_at: string
          id: string
          is_active: boolean
          role: string
          tenant_id: string
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          is_active?: boolean
          role: string
          tenant_id: string
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          is_active?: boolean
          role?: string
          tenant_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "payroll_approvers_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_approvers_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
        ]
      }
      petty_cash_floats: {
        Row: {
          ceiling_amount: number
          cost_center_id: string
          created_at: string
          currency: string
          custodian_user_id: string
          float_name: string
          id: string
          is_active: boolean
          tenant_id: string
          updated_at: string
        }
        Insert: {
          ceiling_amount: number
          cost_center_id: string
          created_at?: string
          currency?: string
          custodian_user_id: string
          float_name: string
          id?: string
          is_active?: boolean
          tenant_id: string
          updated_at?: string
        }
        Update: {
          ceiling_amount?: number
          cost_center_id?: string
          created_at?: string
          currency?: string
          custodian_user_id?: string
          float_name?: string
          id?: string
          is_active?: boolean
          tenant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "petty_cash_floats_cost_center_id_fkey"
            columns: ["cost_center_id"]
            isOneToOne: false
            referencedRelation: "cost_centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "petty_cash_floats_custodian_user_id_fkey"
            columns: ["custodian_user_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "petty_cash_floats_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      petty_cash_replenishments: {
        Row: {
          amount: number
          bank_account: string | null
          created_at: string
          description: string | null
          funded_from: string
          id: string
          petty_cash_float_id: string
          recorded_by: string
          replenished_date: string
          tenant_id: string
        }
        Insert: {
          amount: number
          bank_account?: string | null
          created_at?: string
          description?: string | null
          funded_from: string
          id?: string
          petty_cash_float_id: string
          recorded_by?: string
          replenished_date: string
          tenant_id: string
        }
        Update: {
          amount?: number
          bank_account?: string | null
          created_at?: string
          description?: string | null
          funded_from?: string
          id?: string
          petty_cash_float_id?: string
          recorded_by?: string
          replenished_date?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "petty_cash_replenishments_petty_cash_float_id_fkey"
            columns: ["petty_cash_float_id"]
            isOneToOne: false
            referencedRelation: "petty_cash_float_balances"
            referencedColumns: ["petty_cash_float_id"]
          },
          {
            foreignKeyName: "petty_cash_replenishments_petty_cash_float_id_fkey"
            columns: ["petty_cash_float_id"]
            isOneToOne: false
            referencedRelation: "petty_cash_floats"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "petty_cash_replenishments_recorded_by_fkey"
            columns: ["recorded_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "petty_cash_replenishments_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      platform_settings: {
        Row: {
          branding: Json
          id: boolean
          notifications: Json
          security: Json
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          branding?: Json
          id?: boolean
          notifications?: Json
          security?: Json
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          branding?: Json
          id?: boolean
          notifications?: Json
          security?: Json
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      pmo_milestones: {
        Row: {
          completion_percent: number
          created_at: string
          due_date: string | null
          id: string
          project_id: string
          status: string
          tenant_id: string
          title: string
          updated_at: string
        }
        Insert: {
          completion_percent?: number
          created_at?: string
          due_date?: string | null
          id?: string
          project_id: string
          status?: string
          tenant_id: string
          title: string
          updated_at?: string
        }
        Update: {
          completion_percent?: number
          created_at?: string
          due_date?: string | null
          id?: string
          project_id?: string
          status?: string
          tenant_id?: string
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "pmo_milestones_project_id_fkey"
            columns: ["project_id"]
            isOneToOne: false
            referencedRelation: "pmo_projects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pmo_milestones_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      pmo_project_categories: {
        Row: {
          created_at: string
          description: string | null
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        Insert: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
        }
        Update: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "pmo_project_categories_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      pmo_projects: {
        Row: {
          budget: number | null
          category_id: string | null
          client_name: string | null
          created_at: string
          currency: string
          description: string | null
          end_date: string | null
          id: string
          manager_id: string | null
          name: string
          project_no: string
          start_date: string | null
          status: string
          tenant_id: string
          updated_at: string
        }
        Insert: {
          budget?: number | null
          category_id?: string | null
          client_name?: string | null
          created_at?: string
          currency?: string
          description?: string | null
          end_date?: string | null
          id?: string
          manager_id?: string | null
          name: string
          project_no: string
          start_date?: string | null
          status?: string
          tenant_id: string
          updated_at?: string
        }
        Update: {
          budget?: number | null
          category_id?: string | null
          client_name?: string | null
          created_at?: string
          currency?: string
          description?: string | null
          end_date?: string | null
          id?: string
          manager_id?: string | null
          name?: string
          project_no?: string
          start_date?: string | null
          status?: string
          tenant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "pmo_projects_category_id_fkey"
            columns: ["category_id"]
            isOneToOne: false
            referencedRelation: "pmo_project_categories"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pmo_projects_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pmo_projects_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      pmo_resource_allocations: {
        Row: {
          allocation_percent: number
          created_at: string
          employee_id: string | null
          end_date: string | null
          id: string
          project_id: string | null
          start_date: string | null
          status: string
          tenant_id: string
          updated_at: string
        }
        Insert: {
          allocation_percent?: number
          created_at?: string
          employee_id?: string | null
          end_date?: string | null
          id?: string
          project_id?: string | null
          start_date?: string | null
          status?: string
          tenant_id: string
          updated_at?: string
        }
        Update: {
          allocation_percent?: number
          created_at?: string
          employee_id?: string | null
          end_date?: string | null
          id?: string
          project_id?: string | null
          start_date?: string | null
          status?: string
          tenant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "pmo_resource_allocations_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "hr_employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pmo_resource_allocations_project_id_fkey"
            columns: ["project_id"]
            isOneToOne: false
            referencedRelation: "pmo_projects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pmo_resource_allocations_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      pmo_task_types: {
        Row: {
          created_at: string
          description: string | null
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        Insert: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
        }
        Update: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "pmo_task_types_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      pmo_tasks: {
        Row: {
          assignee_id: string | null
          created_at: string
          due_date: string | null
          id: string
          priority: string
          project_id: string | null
          start_date: string | null
          status: string
          tenant_id: string
          title: string
          type_id: string | null
          updated_at: string
        }
        Insert: {
          assignee_id?: string | null
          created_at?: string
          due_date?: string | null
          id?: string
          priority?: string
          project_id?: string | null
          start_date?: string | null
          status?: string
          tenant_id: string
          title: string
          type_id?: string | null
          updated_at?: string
        }
        Update: {
          assignee_id?: string | null
          created_at?: string
          due_date?: string | null
          id?: string
          priority?: string
          project_id?: string | null
          start_date?: string | null
          status?: string
          tenant_id?: string
          title?: string
          type_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "pmo_tasks_assignee_id_fkey"
            columns: ["assignee_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pmo_tasks_project_id_fkey"
            columns: ["project_id"]
            isOneToOne: false
            referencedRelation: "pmo_projects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pmo_tasks_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pmo_tasks_type_id_fkey"
            columns: ["type_id"]
            isOneToOne: false
            referencedRelation: "pmo_task_types"
            referencedColumns: ["id"]
          },
        ]
      }
      po_edits: {
        Row: {
          changes: Json
          edited_at: string
          edited_by: string
          id: string
          purchase_order_id: string
          reason: string
        }
        Insert: {
          changes: Json
          edited_at?: string
          edited_by: string
          id?: string
          purchase_order_id: string
          reason: string
        }
        Update: {
          changes?: Json
          edited_at?: string
          edited_by?: string
          id?: string
          purchase_order_id?: string
          reason?: string
        }
        Relationships: [
          {
            foreignKeyName: "po_edits_edited_by_fkey"
            columns: ["edited_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "po_edits_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "po_edits_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "v_request_tracking"
            referencedColumns: ["purchase_order_id"]
          },
        ]
      }
      priority_levels: {
        Row: {
          code: string
          color: string
          id: string
          label: string
          sort_order: number
          tenant_id: string
        }
        Insert: {
          code: string
          color?: string
          id?: string
          label: string
          sort_order?: number
          tenant_id: string
        }
        Update: {
          code?: string
          color?: string
          id?: string
          label?: string
          sort_order?: number
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "priority_levels_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      problem_tickets: {
        Row: {
          linked_at: string
          problem_id: string
          tenant_id: string
          ticket_id: string
        }
        Insert: {
          linked_at?: string
          problem_id: string
          tenant_id: string
          ticket_id: string
        }
        Update: {
          linked_at?: string
          problem_id?: string
          tenant_id?: string
          ticket_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "problem_tickets_problem_id_fkey"
            columns: ["problem_id"]
            isOneToOne: false
            referencedRelation: "problems"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "problem_tickets_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "problem_tickets_ticket_id_fkey"
            columns: ["ticket_id"]
            isOneToOne: false
            referencedRelation: "it_tickets"
            referencedColumns: ["id"]
          },
        ]
      }
      problems: {
        Row: {
          assigned_to: string | null
          category: string | null
          closed_at: string | null
          created_at: string
          created_by: string | null
          description: string | null
          id: string
          priority: string
          problem_number: string | null
          resolved_at: string | null
          root_cause: string | null
          status: string
          tenant_id: string
          title: string
          updated_at: string
        }
        Insert: {
          assigned_to?: string | null
          category?: string | null
          closed_at?: string | null
          created_at?: string
          created_by?: string | null
          description?: string | null
          id?: string
          priority?: string
          problem_number?: string | null
          resolved_at?: string | null
          root_cause?: string | null
          status?: string
          tenant_id: string
          title: string
          updated_at?: string
        }
        Update: {
          assigned_to?: string | null
          category?: string | null
          closed_at?: string | null
          created_at?: string
          created_by?: string | null
          description?: string | null
          id?: string
          priority?: string
          problem_number?: string | null
          resolved_at?: string | null
          root_cause?: string | null
          status?: string
          tenant_id?: string
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "problems_assigned_to_fkey"
            columns: ["assigned_to"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "problems_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "problems_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_orders: {
        Row: {
          amount: number
          completed_at: string | null
          currency: string
          delivered_at: string | null
          generated_at: string
          generated_by: string
          id: string
          initial_po_number: string | null
          payment_conditions: string | null
          pdf_generated_at: string | null
          pdf_storage_path: string | null
          po_number: string
          project_sap_no: string | null
          request_id: string
          shared_with_supplier: boolean
          terms_of_delivery: string | null
          vendor_account_id: string | null
          vendor_name: string
        }
        Insert: {
          amount: number
          completed_at?: string | null
          currency?: string
          delivered_at?: string | null
          generated_at?: string
          generated_by: string
          id?: string
          initial_po_number?: string | null
          payment_conditions?: string | null
          pdf_generated_at?: string | null
          pdf_storage_path?: string | null
          po_number: string
          project_sap_no?: string | null
          request_id: string
          shared_with_supplier?: boolean
          terms_of_delivery?: string | null
          vendor_account_id?: string | null
          vendor_name: string
        }
        Update: {
          amount?: number
          completed_at?: string | null
          currency?: string
          delivered_at?: string | null
          generated_at?: string
          generated_by?: string
          id?: string
          initial_po_number?: string | null
          payment_conditions?: string | null
          pdf_generated_at?: string | null
          pdf_storage_path?: string | null
          po_number?: string
          project_sap_no?: string | null
          request_id?: string
          shared_with_supplier?: boolean
          terms_of_delivery?: string | null
          vendor_account_id?: string | null
          vendor_name?: string
        }
        Relationships: [
          {
            foreignKeyName: "purchase_orders_generated_by_fkey"
            columns: ["generated_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_orders_request_id_fkey"
            columns: ["request_id"]
            isOneToOne: false
            referencedRelation: "requests"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_orders_request_id_fkey"
            columns: ["request_id"]
            isOneToOne: false
            referencedRelation: "v_request_tracking"
            referencedColumns: ["request_id"]
          },
          {
            foreignKeyName: "purchase_orders_vendor_account_id_fkey"
            columns: ["vendor_account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_orders_vendor_account_id_fkey"
            columns: ["vendor_account_id"]
            isOneToOne: false
            referencedRelation: "v_trial_balance"
            referencedColumns: ["account_id"]
          },
          {
            foreignKeyName: "purchase_orders_vendor_account_id_fkey"
            columns: ["vendor_account_id"]
            isOneToOne: false
            referencedRelation: "v_vendor_evaluation"
            referencedColumns: ["vendor_account_id"]
          },
        ]
      }
      receivable_invoices: {
        Row: {
          amount_incl_vat: number
          client_account_id: string | null
          cost_center_id: string | null
          created_at: string
          currency: string
          description: string | null
          due_date: string | null
          id: string
          invoice_date: string
          invoice_number: string
          organization_id: string
          prf_oif_number: string
          recorded_by: string
          status: string
          tenant_id: string
          updated_at: string
          vat_amount: number
        }
        Insert: {
          amount_incl_vat: number
          client_account_id?: string | null
          cost_center_id?: string | null
          created_at?: string
          currency?: string
          description?: string | null
          due_date?: string | null
          id?: string
          invoice_date: string
          invoice_number: string
          organization_id: string
          prf_oif_number: string
          recorded_by?: string
          status?: string
          tenant_id: string
          updated_at?: string
          vat_amount?: number
        }
        Update: {
          amount_incl_vat?: number
          client_account_id?: string | null
          cost_center_id?: string | null
          created_at?: string
          currency?: string
          description?: string | null
          due_date?: string | null
          id?: string
          invoice_date?: string
          invoice_number?: string
          organization_id?: string
          prf_oif_number?: string
          recorded_by?: string
          status?: string
          tenant_id?: string
          updated_at?: string
          vat_amount?: number
        }
        Relationships: [
          {
            foreignKeyName: "receivable_invoices_client_account_id_fkey"
            columns: ["client_account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "receivable_invoices_client_account_id_fkey"
            columns: ["client_account_id"]
            isOneToOne: false
            referencedRelation: "v_trial_balance"
            referencedColumns: ["account_id"]
          },
          {
            foreignKeyName: "receivable_invoices_client_account_id_fkey"
            columns: ["client_account_id"]
            isOneToOne: false
            referencedRelation: "v_vendor_evaluation"
            referencedColumns: ["vendor_account_id"]
          },
          {
            foreignKeyName: "receivable_invoices_cost_center_id_fkey"
            columns: ["cost_center_id"]
            isOneToOne: false
            referencedRelation: "cost_centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "receivable_invoices_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "receivable_invoices_recorded_by_fkey"
            columns: ["recorded_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "receivable_invoices_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      request_line_items: {
        Row: {
          cost_code: string | null
          created_at: string
          currency: string
          group_code: string | null
          id: string
          material_service: string
          place_of_use: string | null
          quantity: number
          request_id: string
          total: number | null
          unit_price: number | null
        }
        Insert: {
          cost_code?: string | null
          created_at?: string
          currency?: string
          group_code?: string | null
          id?: string
          material_service: string
          place_of_use?: string | null
          quantity: number
          request_id: string
          total?: number | null
          unit_price?: number | null
        }
        Update: {
          cost_code?: string | null
          created_at?: string
          currency?: string
          group_code?: string | null
          id?: string
          material_service?: string
          place_of_use?: string | null
          quantity?: number
          request_id?: string
          total?: number | null
          unit_price?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "request_line_items_request_id_fkey"
            columns: ["request_id"]
            isOneToOne: false
            referencedRelation: "requests"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "request_line_items_request_id_fkey"
            columns: ["request_id"]
            isOneToOne: false
            referencedRelation: "v_request_tracking"
            referencedColumns: ["request_id"]
          },
        ]
      }
      request_offers: {
        Row: {
          id: string
          is_selected: boolean
          quantity: number
          quotation_amount: number
          request_id: string
          submitted_at: string
          submitted_by: string
          vendor_account_id: string | null
          vendor_name: string
        }
        Insert: {
          id?: string
          is_selected?: boolean
          quantity?: number
          quotation_amount: number
          request_id: string
          submitted_at?: string
          submitted_by: string
          vendor_account_id?: string | null
          vendor_name: string
        }
        Update: {
          id?: string
          is_selected?: boolean
          quantity?: number
          quotation_amount?: number
          request_id?: string
          submitted_at?: string
          submitted_by?: string
          vendor_account_id?: string | null
          vendor_name?: string
        }
        Relationships: [
          {
            foreignKeyName: "request_offers_request_id_fkey"
            columns: ["request_id"]
            isOneToOne: false
            referencedRelation: "requests"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "request_offers_request_id_fkey"
            columns: ["request_id"]
            isOneToOne: false
            referencedRelation: "v_request_tracking"
            referencedColumns: ["request_id"]
          },
          {
            foreignKeyName: "request_offers_submitted_by_fkey"
            columns: ["submitted_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "request_offers_vendor_account_id_fkey"
            columns: ["vendor_account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "request_offers_vendor_account_id_fkey"
            columns: ["vendor_account_id"]
            isOneToOne: false
            referencedRelation: "v_trial_balance"
            referencedColumns: ["account_id"]
          },
          {
            foreignKeyName: "request_offers_vendor_account_id_fkey"
            columns: ["vendor_account_id"]
            isOneToOne: false
            referencedRelation: "v_vendor_evaluation"
            referencedColumns: ["vendor_account_id"]
          },
        ]
      }
      requests: {
        Row: {
          cost_center_id: string | null
          created_at: string
          current_stage_id: string | null
          delivery_date: string | null
          department_id: string
          id: string
          item_description: string
          mr_number: string
          organization_id: string | null
          quantity: number
          replaces_request_id: string | null
          requester_id: string
          status: string
          subcontractor: string | null
          tenant_id: string
          updated_at: string
        }
        Insert: {
          cost_center_id?: string | null
          created_at?: string
          current_stage_id?: string | null
          delivery_date?: string | null
          department_id: string
          id?: string
          item_description: string
          mr_number: string
          organization_id?: string | null
          quantity?: number
          replaces_request_id?: string | null
          requester_id: string
          status?: string
          subcontractor?: string | null
          tenant_id: string
          updated_at?: string
        }
        Update: {
          cost_center_id?: string | null
          created_at?: string
          current_stage_id?: string | null
          delivery_date?: string | null
          department_id?: string
          id?: string
          item_description?: string
          mr_number?: string
          organization_id?: string | null
          quantity?: number
          replaces_request_id?: string | null
          requester_id?: string
          status?: string
          subcontractor?: string | null
          tenant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "requests_cost_center_id_fkey"
            columns: ["cost_center_id"]
            isOneToOne: false
            referencedRelation: "cost_centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "requests_current_stage_id_fkey"
            columns: ["current_stage_id"]
            isOneToOne: false
            referencedRelation: "workflow_stages"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "requests_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "requests_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "requests_replaces_request_id_fkey"
            columns: ["replaces_request_id"]
            isOneToOne: false
            referencedRelation: "requests"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "requests_replaces_request_id_fkey"
            columns: ["replaces_request_id"]
            isOneToOne: false
            referencedRelation: "v_request_tracking"
            referencedColumns: ["request_id"]
          },
          {
            foreignKeyName: "requests_requester_id_fkey"
            columns: ["requester_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "requests_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      sap_payments: {
        Row: {
          amount: number
          created_at: string
          id: string
          purchase_order_id: string
          recorded_by: string
          sap_reference: string | null
          status: string
          tenant_id: string
        }
        Insert: {
          amount: number
          created_at?: string
          id?: string
          purchase_order_id: string
          recorded_by?: string
          sap_reference?: string | null
          status?: string
          tenant_id: string
        }
        Update: {
          amount?: number
          created_at?: string
          id?: string
          purchase_order_id?: string
          recorded_by?: string
          sap_reference?: string | null
          status?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "sap_payments_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sap_payments_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "v_request_tracking"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "sap_payments_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      sla_policies: {
        Row: {
          description: string | null
          id: string
          priority: string
          target_hours: number
          tenant_id: string
          updated_at: string
        }
        Insert: {
          description?: string | null
          id?: string
          priority: string
          target_hours: number
          tenant_id: string
          updated_at?: string
        }
        Update: {
          description?: string | null
          id?: string
          priority?: string
          target_hours?: number
          tenant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "sla_policies_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      staff_roles: {
        Row: {
          created_at: string
          id: string
          module: string
          role: string
          tenant_id: string
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          module: string
          role: string
          tenant_id: string
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          module?: string
          role?: string
          tenant_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "staff_roles_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_roles_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
        ]
      }
      stock_balances: {
        Row: {
          id: string
          material_catalog_id: string | null
          material_name: string
          quantity_on_hand: number
          stock_key: string | null
          tenant_id: string
          unit: string | null
          updated_at: string
          warehouse_id: string
        }
        Insert: {
          id?: string
          material_catalog_id?: string | null
          material_name: string
          quantity_on_hand?: number
          stock_key?: string | null
          tenant_id: string
          unit?: string | null
          updated_at?: string
          warehouse_id: string
        }
        Update: {
          id?: string
          material_catalog_id?: string | null
          material_name?: string
          quantity_on_hand?: number
          stock_key?: string | null
          tenant_id?: string
          unit?: string | null
          updated_at?: string
          warehouse_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "stock_balances_material_catalog_id_fkey"
            columns: ["material_catalog_id"]
            isOneToOne: false
            referencedRelation: "material_catalog"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_balances_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_balances_warehouse_id_fkey"
            columns: ["warehouse_id"]
            isOneToOne: false
            referencedRelation: "warehouses"
            referencedColumns: ["id"]
          },
        ]
      }
      stock_movements: {
        Row: {
          id: string
          material_catalog_id: string | null
          material_name: string
          movement_type: string
          occurred_at: string
          quantity: number
          recorded_by: string
          reference_id: string
          reference_type: string
          tenant_id: string
          unit: string | null
          warehouse_id: string
        }
        Insert: {
          id?: string
          material_catalog_id?: string | null
          material_name: string
          movement_type: string
          occurred_at?: string
          quantity: number
          recorded_by: string
          reference_id: string
          reference_type: string
          tenant_id: string
          unit?: string | null
          warehouse_id: string
        }
        Update: {
          id?: string
          material_catalog_id?: string | null
          material_name?: string
          movement_type?: string
          occurred_at?: string
          quantity?: number
          recorded_by?: string
          reference_id?: string
          reference_type?: string
          tenant_id?: string
          unit?: string | null
          warehouse_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "stock_movements_material_catalog_id_fkey"
            columns: ["material_catalog_id"]
            isOneToOne: false
            referencedRelation: "material_catalog"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_recorded_by_fkey"
            columns: ["recorded_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_warehouse_id_fkey"
            columns: ["warehouse_id"]
            isOneToOne: false
            referencedRelation: "warehouses"
            referencedColumns: ["id"]
          },
        ]
      }
      supplier_invoices: {
        Row: {
          amount_incl_vat: number
          cost_center_id: string | null
          created_at: string
          currency: string
          description: string | null
          due_date: string | null
          id: string
          invoice_date: string
          invoice_number: string
          invoice_type: string | null
          organization_id: string
          prf_oif_number: string
          purchase_order_id: string | null
          recorded_by: string
          tenant_id: string
          updated_at: string
          vat_amount: number
          vendor_account_id: string | null
        }
        Insert: {
          amount_incl_vat: number
          cost_center_id?: string | null
          created_at?: string
          currency?: string
          description?: string | null
          due_date?: string | null
          id?: string
          invoice_date: string
          invoice_number: string
          invoice_type?: string | null
          organization_id: string
          prf_oif_number: string
          purchase_order_id?: string | null
          recorded_by?: string
          tenant_id: string
          updated_at?: string
          vat_amount?: number
          vendor_account_id?: string | null
        }
        Update: {
          amount_incl_vat?: number
          cost_center_id?: string | null
          created_at?: string
          currency?: string
          description?: string | null
          due_date?: string | null
          id?: string
          invoice_date?: string
          invoice_number?: string
          invoice_type?: string | null
          organization_id?: string
          prf_oif_number?: string
          purchase_order_id?: string | null
          recorded_by?: string
          tenant_id?: string
          updated_at?: string
          vat_amount?: number
          vendor_account_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "supplier_invoices_cost_center_id_fkey"
            columns: ["cost_center_id"]
            isOneToOne: false
            referencedRelation: "cost_centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supplier_invoices_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supplier_invoices_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supplier_invoices_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "v_request_tracking"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "supplier_invoices_recorded_by_fkey"
            columns: ["recorded_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supplier_invoices_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supplier_invoices_vendor_account_id_fkey"
            columns: ["vendor_account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supplier_invoices_vendor_account_id_fkey"
            columns: ["vendor_account_id"]
            isOneToOne: false
            referencedRelation: "v_trial_balance"
            referencedColumns: ["account_id"]
          },
          {
            foreignKeyName: "supplier_invoices_vendor_account_id_fkey"
            columns: ["vendor_account_id"]
            isOneToOne: false
            referencedRelation: "v_vendor_evaluation"
            referencedColumns: ["vendor_account_id"]
          },
        ]
      }
      support_team_members: {
        Row: {
          added_at: string
          team_id: string
          user_id: string
        }
        Insert: {
          added_at?: string
          team_id: string
          user_id: string
        }
        Update: {
          added_at?: string
          team_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "support_team_members_team_id_fkey"
            columns: ["team_id"]
            isOneToOne: false
            referencedRelation: "support_teams"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "support_team_members_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
        ]
      }
      support_teams: {
        Row: {
          created_at: string
          description: string | null
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        Insert: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
        }
        Update: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "support_teams_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      sustainability_audits: {
        Row: {
          audit_date: string | null
          created_at: string
          created_by: string | null
          findings: string | null
          id: string
          status: string
          tenant_id: string
          title: string
          type: string | null
        }
        Insert: {
          audit_date?: string | null
          created_at?: string
          created_by?: string | null
          findings?: string | null
          id?: string
          status?: string
          tenant_id: string
          title: string
          type?: string | null
        }
        Update: {
          audit_date?: string | null
          created_at?: string
          created_by?: string | null
          findings?: string | null
          id?: string
          status?: string
          tenant_id?: string
          title?: string
          type?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "sustainability_audits_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sustainability_audits_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      sustainability_certifications: {
        Row: {
          created_at: string
          created_by: string | null
          expiry_date: string | null
          id: string
          issue_date: string | null
          name: string
          standard: string | null
          status: string
          tenant_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          expiry_date?: string | null
          id?: string
          issue_date?: string | null
          name: string
          standard?: string | null
          status?: string
          tenant_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          expiry_date?: string | null
          id?: string
          issue_date?: string | null
          name?: string
          standard?: string | null
          status?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "sustainability_certifications_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sustainability_certifications_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      sustainability_initiative_categories: {
        Row: {
          created_at: string
          description: string | null
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        Insert: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
        }
        Update: {
          created_at?: string
          description?: string | null
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "sustainability_initiative_categories_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      sustainability_initiatives: {
        Row: {
          category_id: string | null
          created_at: string
          created_by: string | null
          current_value: number | null
          description: string | null
          end_date: string | null
          id: string
          owner: string | null
          start_date: string | null
          status: string
          target_value: number | null
          tenant_id: string
          title: string
          updated_at: string
        }
        Insert: {
          category_id?: string | null
          created_at?: string
          created_by?: string | null
          current_value?: number | null
          description?: string | null
          end_date?: string | null
          id?: string
          owner?: string | null
          start_date?: string | null
          status?: string
          target_value?: number | null
          tenant_id: string
          title: string
          updated_at?: string
        }
        Update: {
          category_id?: string | null
          created_at?: string
          created_by?: string | null
          current_value?: number | null
          description?: string | null
          end_date?: string | null
          id?: string
          owner?: string | null
          start_date?: string | null
          status?: string
          target_value?: number | null
          tenant_id?: string
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "sustainability_initiatives_category_id_fkey"
            columns: ["category_id"]
            isOneToOne: false
            referencedRelation: "sustainability_initiative_categories"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sustainability_initiatives_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sustainability_initiatives_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      sustainability_metric_types: {
        Row: {
          created_at: string
          id: string
          is_active: boolean
          name: string
          tenant_id: string
          type: string
          unit: string | null
        }
        Insert: {
          created_at?: string
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
          type?: string
          unit?: string | null
        }
        Update: {
          created_at?: string
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
          type?: string
          unit?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "sustainability_metric_types_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      sustainability_metrics: {
        Row: {
          created_at: string
          created_by: string | null
          id: string
          metric_type_id: string | null
          notes: string | null
          recorded_date: string
          tenant_id: string
          type: string
          unit: string | null
          value: number
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          id?: string
          metric_type_id?: string | null
          notes?: string | null
          recorded_date?: string
          tenant_id: string
          type?: string
          unit?: string | null
          value: number
        }
        Update: {
          created_at?: string
          created_by?: string | null
          id?: string
          metric_type_id?: string | null
          notes?: string | null
          recorded_date?: string
          tenant_id?: string
          type?: string
          unit?: string | null
          value?: number
        }
        Relationships: [
          {
            foreignKeyName: "sustainability_metrics_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sustainability_metrics_metric_type_id_fkey"
            columns: ["metric_type_id"]
            isOneToOne: false
            referencedRelation: "sustainability_metric_types"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sustainability_metrics_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      tenant_modules: {
        Row: {
          enabled_at: string
          enabled_by: string | null
          module: string
          tenant_id: string
        }
        Insert: {
          enabled_at?: string
          enabled_by?: string | null
          module: string
          tenant_id: string
        }
        Update: {
          enabled_at?: string
          enabled_by?: string | null
          module?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "tenant_modules_enabled_by_fkey"
            columns: ["enabled_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tenant_modules_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      tenants: {
        Row: {
          created_at: string
          created_by: string | null
          id: string
          industry_template: string
          name: string
          status: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          id?: string
          industry_template?: string
          name: string
          status?: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          id?: string
          industry_template?: string
          name?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "tenants_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
        ]
      }
      ticket_categories: {
        Row: {
          code: string
          created_at: string
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        Insert: {
          code: string
          created_at?: string
          id?: string
          is_active?: boolean
          name: string
          tenant_id: string
        }
        Update: {
          code?: string
          created_at?: string
          id?: string
          is_active?: boolean
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "ticket_categories_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      user_group_members: {
        Row: {
          added_at: string
          group_id: string
          user_id: string
        }
        Insert: {
          added_at?: string
          group_id: string
          user_id: string
        }
        Update: {
          added_at?: string
          group_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_group_members_group_id_fkey"
            columns: ["group_id"]
            isOneToOne: false
            referencedRelation: "user_groups"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "user_group_members_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
        ]
      }
      user_groups: {
        Row: {
          created_at: string
          description: string | null
          id: string
          name: string
          tenant_id: string
        }
        Insert: {
          created_at?: string
          description?: string | null
          id?: string
          name: string
          tenant_id: string
        }
        Update: {
          created_at?: string
          description?: string | null
          id?: string
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_groups_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      warehouses: {
        Row: {
          code: string | null
          created_at: string
          created_by: string | null
          department_id: string | null
          id: string
          is_active: boolean
          name: string
          project_label: string | null
          tenant_id: string
        }
        Insert: {
          code?: string | null
          created_at?: string
          created_by?: string | null
          department_id?: string | null
          id?: string
          is_active?: boolean
          name: string
          project_label?: string | null
          tenant_id: string
        }
        Update: {
          code?: string | null
          created_at?: string
          created_by?: string | null
          department_id?: string | null
          id?: string
          is_active?: boolean
          name?: string
          project_label?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "warehouses_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "warehouses_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "warehouses_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      workflow_stages: {
        Row: {
          applies_to: string
          approver_role: string
          blocks_offer_submitter_approval: boolean
          created_at: string
          id: string
          is_active: boolean
          is_finance_terminal_stage: boolean
          name: string
          next_stage_high_id: string | null
          next_stage_low_id: string | null
          requires_offer_entry: boolean
          requires_offer_selection: boolean
          sequence_order: number
          tenant_id: string
          threshold_amount: number | null
        }
        Insert: {
          applies_to?: string
          approver_role: string
          blocks_offer_submitter_approval?: boolean
          created_at?: string
          id?: string
          is_active?: boolean
          is_finance_terminal_stage?: boolean
          name: string
          next_stage_high_id?: string | null
          next_stage_low_id?: string | null
          requires_offer_entry?: boolean
          requires_offer_selection?: boolean
          sequence_order: number
          tenant_id: string
          threshold_amount?: number | null
        }
        Update: {
          applies_to?: string
          approver_role?: string
          blocks_offer_submitter_approval?: boolean
          created_at?: string
          id?: string
          is_active?: boolean
          is_finance_terminal_stage?: boolean
          name?: string
          next_stage_high_id?: string | null
          next_stage_low_id?: string | null
          requires_offer_entry?: boolean
          requires_offer_selection?: boolean
          sequence_order?: number
          tenant_id?: string
          threshold_amount?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "workflow_stages_next_stage_high_id_fkey"
            columns: ["next_stage_high_id"]
            isOneToOne: false
            referencedRelation: "workflow_stages"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_stages_next_stage_low_id_fkey"
            columns: ["next_stage_low_id"]
            isOneToOne: false
            referencedRelation: "workflow_stages"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_stages_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      hr_employee_current_compensation: {
        Row: {
          basic_salary: number | null
          contract_reference: string | null
          currency: string | null
          effective_date: string | null
          employee_id: string | null
          tenant_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "hr_employee_compensation_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "hr_employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hr_employee_compensation_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      line_item_receipt_status: {
        Row: {
          last_received_at: string | null
          line_item_id: string | null
          material_service: string | null
          ordered_qty: number | null
          receipt_status: string | null
          received_qty: number | null
          request_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "request_line_items_request_id_fkey"
            columns: ["request_id"]
            isOneToOne: false
            referencedRelation: "requests"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "request_line_items_request_id_fkey"
            columns: ["request_id"]
            isOneToOne: false
            referencedRelation: "v_request_tracking"
            referencedColumns: ["request_id"]
          },
        ]
      }
      petty_cash_float_balances: {
        Row: {
          ceiling_amount: number | null
          cost_center_id: string | null
          currency: string | null
          current_balance: number | null
          custodian_user_id: string | null
          float_name: string | null
          is_active: boolean | null
          petty_cash_float_id: string | null
          tenant_id: string | null
          total_replenished: number | null
          total_spent: number | null
        }
        Relationships: [
          {
            foreignKeyName: "petty_cash_floats_cost_center_id_fkey"
            columns: ["cost_center_id"]
            isOneToOne: false
            referencedRelation: "cost_centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "petty_cash_floats_custodian_user_id_fkey"
            columns: ["custodian_user_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "petty_cash_floats_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      v_account_ledger: {
        Row: {
          account_id: string | null
          credit: number | null
          currency: string | null
          debit: number | null
          reference_no: string | null
          source_id: string | null
          source_type: string | null
          tenant_id: string | null
          transaction_date: string | null
        }
        Relationships: []
      }
      v_advance_payments: {
        Row: {
          account_code: string | null
          account_id: string | null
          account_name: string | null
          amount: number | null
          currency: string | null
          description: string | null
          direction: string | null
          id: string | null
          payment_date: string | null
          payment_method: string | null
          remaining_amount: number | null
          tenant_id: string | null
          total_applied: number | null
        }
        Relationships: [
          {
            foreignKeyName: "advance_payments_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "advance_payments_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "v_trial_balance"
            referencedColumns: ["account_id"]
          },
          {
            foreignKeyName: "advance_payments_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "v_vendor_evaluation"
            referencedColumns: ["vendor_account_id"]
          },
          {
            foreignKeyName: "advance_payments_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      v_cost_transactions_inquiry: {
        Row: {
          amount: number | null
          cost_center_id: string | null
          currency: string | null
          reference_no: string | null
          source_id: string | null
          source_type: string | null
          tenant_id: string | null
          transaction_date: string | null
        }
        Relationships: []
      }
      v_durations: {
        Row: {
          currency: string | null
          days_outstanding: number | null
          invoice_date: string | null
          invoice_number: string | null
          outstanding_amount: number | null
          source_id: string | null
          source_type: string | null
          status: string | null
          tenant_id: string | null
        }
        Relationships: []
      }
      v_payment_plan: {
        Row: {
          currency: string | null
          due_date: string | null
          invoice_date: string | null
          invoice_number: string | null
          outstanding_amount: number | null
          source_id: string | null
          source_type: string | null
          tenant_id: string | null
        }
        Relationships: []
      }
      v_request_tracking: {
        Row: {
          closing_date: string | null
          company: string | null
          company_code: string | null
          cost_code: string | null
          currency: string | null
          delivered_at: string | null
          delivery_date: string | null
          initial_po_number: string | null
          mr_date: string | null
          mr_number: string | null
          mr_originator: string | null
          mr_title: string | null
          organization_id: string | null
          pending_authority: string | null
          place_of_use: string | null
          po_date: string | null
          po_number: string | null
          po_requester_id: string | null
          po_requester_name: string | null
          po_total: number | null
          purchase_order_id: string | null
          request_id: string | null
          requester_id: string | null
          site_name: string | null
          status: string | null
          subcontractor: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_orders_generated_by_fkey"
            columns: ["po_requester_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "requests_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "requests_requester_id_fkey"
            columns: ["requester_id"]
            isOneToOne: false
            referencedRelation: "app_users"
            referencedColumns: ["id"]
          },
        ]
      }
      v_trial_balance: {
        Row: {
          account_code: string | null
          account_id: string | null
          account_name: string | null
          balance: number | null
          category_name: string | null
          currency: string | null
          tenant_id: string | null
          total_credit: number | null
          total_debit: number | null
        }
        Relationships: [
          {
            foreignKeyName: "accounts_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
      v_vat_report: {
        Row: {
          amount_incl_vat: number | null
          currency: string | null
          invoice_date: string | null
          invoice_number: string | null
          organization_id: string | null
          source_id: string | null
          source_type: string | null
          tenant_id: string | null
          vat_amount: number | null
        }
        Relationships: []
      }
      v_vendor_evaluation: {
        Row: {
          account_code: string | null
          avg_days_to_deliver: number | null
          contact_email: string | null
          contact_name: string | null
          contact_phone: string | null
          delivered_pos: number | null
          fulfillment_accuracy_pct: number | null
          is_active: boolean | null
          on_time_delivery_pct: number | null
          over_delivery_pct: number | null
          tenant_id: string | null
          total_po_value: number | null
          total_pos: number | null
          under_delivery_pct: number | null
          vendor_account_id: string | null
          vendor_name: string | null
        }
        Relationships: [
          {
            foreignKeyName: "accounts_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenants"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Functions: {
      add_group_member: {
        Args: { p_group_id: string; p_user_id: string }
        Returns: undefined
      }
      add_support_team_member: {
        Args: { p_team_id: string; p_user_id: string }
        Returns: undefined
      }
      am_i_finance: { Args: never; Returns: boolean }
      approve_all_material_request_items: {
        Args: { p_batch_id: string }
        Returns: {
          code: string | null
          created_at: string | null
          description_en: string | null
          description_fr: string | null
          description_tr: string | null
          external_material_group_id: string | null
          id: string
          is_active: boolean
          material_group_id: string | null
          material_type_id: string | null
          name: string
          old_material_code: string | null
          tenant_id: string
          unit: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "material_catalog"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      approve_line_item_receipt: {
        Args: { p_receipt_id: string }
        Returns: {
          approved_at: string | null
          approved_by: string | null
          id: string
          line_item_id: string
          note: string | null
          received_at: string
          received_by: string
          received_qty: number
          voucher_no: string | null
          warehouse_id: string | null
        }
        SetofOptions: {
          from: "*"
          to: "line_item_receipts"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      approve_material_request_item: {
        Args: { p_item_id: string }
        Returns: {
          code: string | null
          created_at: string | null
          description_en: string | null
          description_fr: string | null
          description_tr: string | null
          external_material_group_id: string | null
          id: string
          is_active: boolean
          material_group_id: string | null
          material_type_id: string | null
          name: string
          old_material_code: string | null
          tenant_id: string
          unit: string | null
        }
        SetofOptions: {
          from: "*"
          to: "material_catalog"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      approve_payroll_run: {
        Args: { p_run_id: string }
        Returns: {
          amount_disbursed: number
          approved_at: string | null
          approved_by: string | null
          created_at: string
          id: string
          period: string
          prepared_by: string
          rejected_at: string | null
          rejected_by: string | null
          rejection_reason: string | null
          status: string
          submitted_at: string | null
          tenant_id: string
        }
        SetofOptions: {
          from: "*"
          to: "hr_payroll_runs"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      assign_asset: {
        Args: { p_asset_id: string; p_assigned_to: string; p_notes?: string }
        Returns: {
          asset_id: string
          assigned_at: string
          assigned_by: string | null
          assigned_to: string
          id: string
          notes: string | null
          returned_at: string | null
          tenant_id: string
        }
        SetofOptions: {
          from: "*"
          to: "asset_assignments"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      assign_receipt_access: {
        Args: { p_user_id: string }
        Returns: {
          assigned_by: string
          created_at: string
          id: string
          tenant_id: string
          user_id: string
        }
        SetofOptions: {
          from: "*"
          to: "material_receipt_assignments"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      assign_ticket: {
        Args: { p_assignee_id?: string; p_ticket_id: string }
        Returns: {
          approval_notes: string | null
          approval_status: string
          approved_at: string | null
          approved_by: string | null
          assignee_id: string | null
          category: string
          closed_at: string | null
          created_at: string
          department_id: string
          description: string
          id: string
          priority: string
          requester_id: string
          requires_approval: boolean
          resolution_notes: string | null
          resolved_at: string | null
          status: string
          subject: string
          tenant_id: string
          ticket_number: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "it_tickets"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      can_access_finance: { Args: never; Returns: boolean }
      can_act_on_stage: { Args: { check_stage_id: string }; Returns: boolean }
      can_manage_po_handoff: {
        Args: { p_purchase_order_id: string }
        Returns: boolean
      }
      cancel_request: {
        Args: { p_reason: string; p_request_id: string }
        Returns: {
          out_request_id: string
          out_status: string
        }[]
      }
      complete_purchase_order_manually: {
        Args: { p_purchase_order_id: string; p_reason: string }
        Returns: {
          amount: number
          completed_at: string | null
          currency: string
          delivered_at: string | null
          generated_at: string
          generated_by: string
          id: string
          initial_po_number: string | null
          payment_conditions: string | null
          pdf_generated_at: string | null
          pdf_storage_path: string | null
          po_number: string
          project_sap_no: string | null
          request_id: string
          shared_with_supplier: boolean
          terms_of_delivery: string | null
          vendor_account_id: string | null
          vendor_name: string
        }
        SetofOptions: {
          from: "*"
          to: "purchase_orders"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      confirm_po_delivered: {
        Args: { p_purchase_order_id: string }
        Returns: {
          amount: number
          completed_at: string | null
          currency: string
          delivered_at: string | null
          generated_at: string
          generated_by: string
          id: string
          initial_po_number: string | null
          payment_conditions: string | null
          pdf_generated_at: string | null
          pdf_storage_path: string | null
          po_number: string
          project_sap_no: string | null
          request_id: string
          shared_with_supplier: boolean
          terms_of_delivery: string | null
          vendor_account_id: string | null
          vendor_name: string
        }
        SetofOptions: {
          from: "*"
          to: "purchase_orders"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_access_request: {
        Args: {
          p_access_level?: string
          p_justification?: string
          p_resource: string
        }
        Returns: {
          access_level: string | null
          created_at: string
          decided_at: string | null
          decided_by: string | null
          decision_notes: string | null
          id: string
          justification: string | null
          requested_by: string
          resource: string
          status: string
          tenant_id: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "access_requests"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_asset: {
        Args: {
          p_category?: string
          p_name: string
          p_notes?: string
          p_purchase_cost?: number
          p_purchase_date?: string
          p_serial_number?: string
          p_type: string
          p_vendor?: string
        }
        Returns: {
          asset_tag: string | null
          category: string | null
          created_at: string
          id: string
          name: string
          notes: string | null
          purchase_cost: number | null
          purchase_date: string | null
          serial_number: string | null
          status: string
          tenant_id: string
          type: string
          updated_at: string
          vendor: string | null
        }
        SetofOptions: {
          from: "*"
          to: "assets"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_asset_request: {
        Args: {
          p_asset_type: string
          p_item_description: string
          p_justification?: string
        }
        Returns: {
          asset_type: string
          created_at: string
          decided_at: string | null
          decided_by: string | null
          decision_notes: string | null
          fulfilled_asset_id: string | null
          fulfilled_assignment_id: string | null
          id: string
          item_description: string
          justification: string | null
          requested_by: string
          status: string
          tenant_id: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "asset_requests"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_faq: {
        Args: {
          p_answer: string
          p_category?: string
          p_is_published?: boolean
          p_question: string
          p_sort_order?: number
        }
        Returns: {
          answer: string
          category: string | null
          created_at: string
          id: string
          is_published: boolean
          question: string
          sort_order: number
          tenant_id: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "faqs"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_group: {
        Args: { p_description?: string; p_name: string }
        Returns: {
          created_at: string
          description: string | null
          id: string
          name: string
          tenant_id: string
        }
        SetofOptions: {
          from: "*"
          to: "user_groups"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_kb_article: {
        Args: {
          p_category?: string
          p_content: string
          p_is_published?: boolean
          p_title: string
        }
        Returns: {
          category: string | null
          content: string
          created_at: string
          created_by: string | null
          id: string
          is_published: boolean
          tenant_id: string
          title: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "kb_articles"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_license: {
        Args: {
          p_asset_id: string
          p_expiry_date?: string
          p_license_key?: string
          p_notes?: string
          p_seats_total?: number
          p_vendor?: string
        }
        Returns: {
          asset_id: string
          created_at: string
          expiry_date: string | null
          id: string
          license_key: string | null
          notes: string | null
          seats_total: number
          tenant_id: string
          updated_at: string
          vendor: string | null
        }
        SetofOptions: {
          from: "*"
          to: "licenses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_payroll_run: {
        Args: { p_period: string }
        Returns: {
          amount_disbursed: number
          approved_at: string | null
          approved_by: string | null
          created_at: string
          id: string
          period: string
          prepared_by: string
          rejected_at: string | null
          rejected_by: string | null
          rejection_reason: string | null
          status: string
          submitted_at: string | null
          tenant_id: string
        }
        SetofOptions: {
          from: "*"
          to: "hr_payroll_runs"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_problem: {
        Args: {
          p_category?: string
          p_description?: string
          p_priority?: string
          p_title: string
        }
        Returns: {
          assigned_to: string | null
          category: string | null
          closed_at: string | null
          created_at: string
          created_by: string | null
          description: string | null
          id: string
          priority: string
          problem_number: string | null
          resolved_at: string | null
          root_cause: string | null
          status: string
          tenant_id: string
          title: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "problems"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_support_team: {
        Args: { p_description?: string; p_name: string }
        Returns: {
          created_at: string
          description: string | null
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        SetofOptions: {
          from: "*"
          to: "support_teams"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_ticket_category: {
        Args: { p_code: string; p_name: string }
        Returns: {
          code: string
          created_at: string
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        SetofOptions: {
          from: "*"
          to: "ticket_categories"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      decide_access_request: {
        Args: { p_decision: string; p_notes?: string; p_request_id: string }
        Returns: {
          access_level: string | null
          created_at: string
          decided_at: string | null
          decided_by: string | null
          decision_notes: string | null
          id: string
          justification: string | null
          requested_by: string
          resource: string
          status: string
          tenant_id: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "access_requests"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      decide_asset_request: {
        Args: { p_decision: string; p_notes?: string; p_request_id: string }
        Returns: {
          asset_type: string
          created_at: string
          decided_at: string | null
          decided_by: string | null
          decision_notes: string | null
          fulfilled_asset_id: string | null
          fulfilled_assignment_id: string | null
          id: string
          item_description: string
          justification: string | null
          requested_by: string
          status: string
          tenant_id: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "asset_requests"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      edit_purchase_order: {
        Args: {
          p_amount: number
          p_currency?: string
          p_delivery_date?: string
          p_initial_po_number?: string
          p_payment_conditions?: string
          p_project_sap_no?: string
          p_purchase_order_id: string
          p_reason: string
          p_terms_of_delivery?: string
          p_vendor_name: string
        }
        Returns: {
          changes: Json
          edited_at: string
          edited_by: string
          id: string
          purchase_order_id: string
          reason: string
        }
        SetofOptions: {
          from: "*"
          to: "po_edits"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      end_impersonation: { Args: never; Returns: undefined }
      fulfill_asset_request: {
        Args: { p_asset_id: string; p_notes?: string; p_request_id: string }
        Returns: {
          asset_type: string
          created_at: string
          decided_at: string | null
          decided_by: string | null
          decision_notes: string | null
          fulfilled_asset_id: string | null
          fulfilled_assignment_id: string | null
          id: string
          item_description: string
          justification: string | null
          requested_by: string
          status: string
          tenant_id: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "asset_requests"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      generate_payroll_items: {
        Args: { p_run_id: string }
        Returns: {
          allowances: number
          basic_salary: number
          deductions: number
          employee_id: string
          id: string
          net_pay: number | null
          note: string | null
          payroll_run_id: string
        }[]
        SetofOptions: {
          from: "*"
          to: "hr_payroll_items"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      get_access_requests: {
        Args: { p_status?: string }
        Returns: {
          access_level: string
          created_at: string
          decided_at: string
          decided_by: string
          decision_notes: string
          id: string
          justification: string
          requested_by: string
          requester_name: string
          resource: string
          status: string
        }[]
      }
      get_active_impersonation: {
        Args: never
        Returns: {
          tenant_id: string
          tenant_name: string
        }[]
      }
      get_all_tickets: {
        Args: never
        Returns: {
          approval_notes: string | null
          approval_status: string
          approved_at: string | null
          approved_by: string | null
          assignee_id: string | null
          category: string
          closed_at: string | null
          created_at: string
          department_id: string
          description: string
          id: string
          priority: string
          requester_id: string
          requires_approval: boolean
          resolution_notes: string | null
          resolved_at: string | null
          status: string
          subject: string
          tenant_id: string
          ticket_number: string
          updated_at: string
        }[]
        SetofOptions: {
          from: "*"
          to: "it_tickets"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      get_asset_assignments: {
        Args: { p_active_only?: boolean }
        Returns: {
          asset_id: string
          asset_name: string
          asset_tag: string
          asset_type: string
          assigned_at: string
          assigned_by: string
          assigned_to: string
          assigned_to_name: string
          id: string
          notes: string
          returned_at: string
        }[]
      }
      get_asset_requests: {
        Args: { p_status?: string }
        Returns: {
          asset_type: string
          created_at: string
          decided_at: string
          decided_by: string
          decision_notes: string
          fulfilled_asset_id: string
          fulfilled_asset_tag: string
          id: string
          item_description: string
          justification: string
          requested_by: string
          requester_name: string
          status: string
        }[]
      }
      get_assets: {
        Args: { p_type?: string }
        Returns: {
          asset_tag: string | null
          category: string | null
          created_at: string
          id: string
          name: string
          notes: string | null
          purchase_cost: number | null
          purchase_date: string | null
          serial_number: string | null
          status: string
          tenant_id: string
          type: string
          updated_at: string
          vendor: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "assets"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      get_companies_overview: {
        Args: never
        Returns: {
          created_at: string
          member_count: number
          module_count: number
          name: string
          pending_request_count: number
          request_count_30d: number
          status: string
          tenant_id: string
        }[]
      }
      get_company_analytics: { Args: { p_tenant_id: string }; Returns: Json }
      get_faqs: {
        Args: { p_category?: string }
        Returns: {
          answer: string
          category: string | null
          created_at: string
          id: string
          is_published: boolean
          question: string
          sort_order: number
          tenant_id: string
          updated_at: string
        }[]
        SetofOptions: {
          from: "*"
          to: "faqs"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      get_group_members: {
        Args: { p_group_id: string }
        Returns: {
          added_at: string
          email: string
          name: string
          user_id: string
        }[]
      }
      get_groups: {
        Args: never
        Returns: {
          created_at: string
          description: string
          id: string
          member_count: number
          name: string
        }[]
      }
      get_kb_articles: {
        Args: { p_category?: string }
        Returns: {
          category: string | null
          content: string
          created_at: string
          created_by: string | null
          id: string
          is_published: boolean
          tenant_id: string
          title: string
          updated_at: string
        }[]
        SetofOptions: {
          from: "*"
          to: "kb_articles"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      get_licenses: {
        Args: never
        Returns: {
          asset_id: string
          asset_name: string
          asset_tag: string
          expiry_date: string
          id: string
          license_key: string
          notes: string
          seats_total: number
          seats_used: number
          vendor: string
        }[]
      }
      get_my_access_requests: {
        Args: never
        Returns: {
          access_level: string | null
          created_at: string
          decided_at: string | null
          decided_by: string | null
          decision_notes: string | null
          id: string
          justification: string | null
          requested_by: string
          resource: string
          status: string
          tenant_id: string
          updated_at: string
        }[]
        SetofOptions: {
          from: "*"
          to: "access_requests"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      get_my_approval_queue: {
        Args: never
        Returns: {
          acting_on_behalf_of: Json
          cost_center: Json
          cost_center_id: string
          created_at: string
          current_stage: Json
          current_stage_id: string
          department: Json
          department_id: string
          id: string
          item_description: string
          offers: Json
          purchase_order: Json
          quantity: number
          requester: Json
          requester_id: string
          selected_offer: Json
          status: string
          tenant_id: string
        }[]
      }
      get_my_asset_requests: {
        Args: never
        Returns: {
          asset_type: string
          created_at: string
          decided_at: string
          decision_notes: string
          fulfilled_asset_id: string
          fulfilled_asset_tag: string
          id: string
          item_description: string
          justification: string
          status: string
        }[]
      }
      get_my_invoice_approval_queue: {
        Args: never
        Returns: {
          acting_on_behalf_of: Json
          amount: number
          cost_center_id: string
          created_at: string
          current_stage: Json
          current_stage_id: string
          department: Json
          department_id: string
          description: string
          id: string
          requester: Json
          requester_id: string
          status: string
          tenant_id: string
          vendor_name: string
        }[]
      }
      get_my_procurement_orders: {
        Args: never
        Returns: {
          amount: number
          completed_at: string
          delivered_at: string
          id: string
          item_description: string
          po_number: string
          request_id: string
          request_status: string
          shared_with_supplier: boolean
          vendor_name: string
        }[]
      }
      get_my_purchase_orders: {
        Args: never
        Returns: {
          amount: number
          completed_at: string
          cost_center: Json
          currency: string
          delivered_at: string
          delivery_date: string
          department: Json
          edit_count: number
          generated_at: string
          generated_by: Json
          id: string
          initial_po_number: string
          last_edited_at: string
          last_edited_by: Json
          mr_number: string
          organization: Json
          payment_conditions: string
          po_number: string
          project_sap_no: string
          request: Json
          request_id: string
          requester: Json
          shared_with_supplier: boolean
          terms_of_delivery: string
          vendor_name: string
        }[]
      }
      get_my_tenant_id: { Args: never; Returns: string }
      get_my_tenant_status: { Args: never; Returns: string }
      get_my_tickets: {
        Args: never
        Returns: {
          approval_notes: string | null
          approval_status: string
          approved_at: string | null
          approved_by: string | null
          assignee_id: string | null
          category: string
          closed_at: string | null
          created_at: string
          department_id: string
          description: string
          id: string
          priority: string
          requester_id: string
          requires_approval: boolean
          resolution_notes: string | null
          resolved_at: string | null
          status: string
          subject: string
          tenant_id: string
          ticket_number: string
          updated_at: string
        }[]
        SetofOptions: {
          from: "*"
          to: "it_tickets"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      get_offer_detail: { Args: { p_request_id: string }; Returns: Json }
      get_pending_material_request_batches: {
        Args: never
        Returns: {
          batch_id: string
          pending_item_count: number
          requested_at: string
          requester_id: string
          requester_name: string
        }[]
      }
      get_pending_ticket_approvals: {
        Args: never
        Returns: {
          approval_notes: string | null
          approval_status: string
          approved_at: string | null
          approved_by: string | null
          assignee_id: string | null
          category: string
          closed_at: string | null
          created_at: string
          department_id: string
          description: string
          id: string
          priority: string
          requester_id: string
          requires_approval: boolean
          resolution_notes: string | null
          resolved_at: string | null
          status: string
          subject: string
          tenant_id: string
          ticket_number: string
          updated_at: string
        }[]
        SetofOptions: {
          from: "*"
          to: "it_tickets"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      get_platform_dashboard_stats: { Args: never; Returns: Json }
      get_po_detail: {
        Args: { p_purchase_order_id: string }
        Returns: {
          completed_at: string
          currency: string
          delivered_at: string
          delivery_date: string
          generated_at: string
          generated_by_name: string
          initial_po_number: string
          mr_date: string
          mr_number: string
          mr_title: string
          offer_quantity: number
          offer_quotation_amount: number
          offer_submitted_at: string
          offer_submitted_by_name: string
          payment_conditions: string
          po_amount: number
          po_number: string
          project_sap_no: string
          purchase_order_id: string
          request_id: string
          requester_name: string
          shared_with_supplier: boolean
          terms_of_delivery: string
          vendor_name: string
        }[]
      }
      get_po_edit_history: {
        Args: { po_id: string }
        Returns: {
          changes: Json
          edited_at: string
          editor: Json
          id: string
          reason: string
        }[]
      }
      get_po_pdf_data: {
        Args: { p_purchase_order_id: string }
        Returns: {
          approvals: Json
          company: string
          currency: string
          delivery_date: string
          initial_po_number: string
          line_items: Json
          mr_number: string
          mr_title: string
          organization_name: string
          payment_conditions: string
          po_date: string
          po_number: string
          po_total: number
          primary_cost_code: string
          project_sap_no: string
          purchase_order_id: string
          purchaser_name: string
          requester_name: string
          terms_of_delivery: string
        }[]
      }
      get_priority_levels: {
        Args: never
        Returns: {
          code: string
          color: string
          id: string
          label: string
          sort_order: number
          tenant_id: string
        }[]
        SetofOptions: {
          from: "*"
          to: "priority_levels"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      get_problem_tickets: {
        Args: { p_problem_id: string }
        Returns: {
          approval_notes: string | null
          approval_status: string
          approved_at: string | null
          approved_by: string | null
          assignee_id: string | null
          category: string
          closed_at: string | null
          created_at: string
          department_id: string
          description: string
          id: string
          priority: string
          requester_id: string
          requires_approval: boolean
          resolution_notes: string | null
          resolved_at: string | null
          status: string
          subject: string
          tenant_id: string
          ticket_number: string
          updated_at: string
        }[]
        SetofOptions: {
          from: "*"
          to: "it_tickets"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      get_problems: {
        Args: never
        Returns: {
          assigned_to: string | null
          category: string | null
          closed_at: string | null
          created_at: string
          created_by: string | null
          description: string | null
          id: string
          priority: string
          problem_number: string | null
          resolved_at: string | null
          root_cause: string | null
          status: string
          tenant_id: string
          title: string
          updated_at: string
        }[]
        SetofOptions: {
          from: "*"
          to: "problems"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      get_procurement_info: {
        Args: {
          p_company?: string
          p_initial_po_number?: string
          p_mr_number?: string
          p_organization_id?: string
          p_po_number?: string
          p_po_status?: string
          p_purchaser?: string
        }
        Returns: {
          company: string
          completed_at: string
          currency: string
          delivered_at: string
          delivery_date: string
          initial_po_number: string
          mr_created_at: string
          mr_number: string
          mr_originator_name: string
          mr_title: string
          pdf_generated_at: string
          pdf_storage_path: string
          po_date: string
          po_number: string
          po_status: string
          po_total: number
          purchase_order_id: string
          request_id: string
          requester_name: string
          shared_with_supplier: boolean
        }[]
      }
      get_request_tracking: {
        Args: {
          p_closing_date_from?: string
          p_closing_date_to?: string
          p_company?: string
          p_cost_code?: string
          p_delivery_date_from?: string
          p_delivery_date_to?: string
          p_description?: string
          p_market_offer_date_from?: string
          p_market_offer_date_to?: string
          p_mr_date_from?: string
          p_mr_date_to?: string
          p_mr_number?: string
          p_mr_originator?: string
          p_organization_id?: string
          p_pending_authority?: string
          p_place_of_use?: string
          p_po_date_from?: string
          p_po_date_to?: string
          p_po_number?: string
          p_status?: string
          p_subcontractor?: string
        }
        Returns: {
          closing_date: string
          company: string
          cost_code: string
          currency: string
          delivery_date: string
          initial_po_number: string
          lifecycle_status: string
          market_offer_date: string
          mr_created_at: string
          mr_date: string
          mr_number: string
          mr_title: string
          order_placer_name: string
          pending_authority: string
          place_of_use: string
          po_date: string
          po_number: string
          po_total: number
          purchase_order_id: string
          request_id: string
          requester_name: string
          status: string
          subcontractor: string
        }[]
      }
      get_sla_policies: {
        Args: never
        Returns: {
          description: string | null
          id: string
          priority: string
          target_hours: number
          tenant_id: string
          updated_at: string
        }[]
        SetofOptions: {
          from: "*"
          to: "sla_policies"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      get_support_team_members: {
        Args: { p_team_id: string }
        Returns: {
          added_at: string
          email: string
          name: string
          user_id: string
        }[]
      }
      get_support_teams: {
        Args: never
        Returns: {
          created_at: string
          description: string
          id: string
          is_active: boolean
          member_count: number
          name: string
        }[]
      }
      get_tenant_modules: { Args: { p_tenant_id: string }; Returns: string[] }
      get_tenant_workflow_stages: {
        Args: { p_tenant_id: string }
        Returns: Json
      }
      get_ticket_categories: {
        Args: never
        Returns: {
          code: string
          created_at: string
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }[]
        SetofOptions: {
          from: "*"
          to: "ticket_categories"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      get_vendor_evaluation: {
        Args: never
        Returns: {
          account_code: string
          avg_days_to_deliver: number
          contact_email: string
          contact_name: string
          contact_phone: string
          delivered_pos: number
          fulfillment_accuracy_pct: number
          is_active: boolean
          on_time_delivery_pct: number
          over_delivery_pct: number
          total_po_value: number
          total_pos: number
          under_delivery_pct: number
          vendor_account_id: string
          vendor_name: string
        }[]
      }
      grant_delegation: {
        Args: {
          p_delegate_user_id: string
          p_ends_at?: string
          p_starts_at?: string
          p_workflow_stage_id?: string
        }
        Returns: {
          created_at: string
          delegate_user_id: string
          delegator_user_id: string
          ends_at: string
          id: string
          starts_at: string
          status: string
          tenant_id: string
          workflow_stage_id: string | null
        }
        SetofOptions: {
          from: "*"
          to: "approval_delegations"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      has_module_role: {
        Args: { p_module: string; p_roles: string[] }
        Returns: boolean
      }
      has_po_access: { Args: never; Returns: boolean }
      has_receipt_access: { Args: never; Returns: boolean }
      is_any_module_admin: { Args: never; Returns: boolean }
      is_business_dev: { Args: never; Returns: boolean }
      is_finance_team_member: { Args: { p_role?: string }; Returns: boolean }
      is_hr_team_member: { Args: { p_role?: string }; Returns: boolean }
      is_it_support: { Args: never; Returns: boolean }
      is_payroll_approver: { Args: never; Returns: boolean }
      is_platform_admin: { Args: never; Returns: boolean }
      link_ticket_to_problem: {
        Args: { p_problem_id: string; p_ticket_id: string }
        Returns: undefined
      }
      list_receipt_assignees: {
        Args: never
        Returns: {
          assigned_by_name: string
          created_at: string
          id: string
          user_id: string
          user_name: string
        }[]
      }
      next_asset_tag: { Args: { p_tenant_id: string }; Returns: string }
      next_doc_number: {
        Args: {
          p_doc_type: string
          p_pad?: number
          p_prefix: string
          p_tenant_id: string
        }
        Returns: string
      }
      next_material_catalog_code: {
        Args: { p_tenant_id: string }
        Returns: string
      }
      next_mr_number: { Args: { p_tenant_id: string }; Returns: string }
      next_problem_number: { Args: { p_tenant_id: string }; Returns: string }
      next_ticket_number: { Args: { p_tenant_id: string }; Returns: string }
      platform_has_admin: { Args: never; Returns: boolean }
      record_approval_decision: {
        Args: {
          p_acting_on_behalf_of?: string
          p_comment?: string
          p_decision: string
          p_request_id: string
          p_selected_offer_id?: string
        }
        Returns: {
          out_purchase_order_id: string
          out_request_id: string
          out_stage_id: string
          out_status: string
        }[]
      }
      record_employee_compensation: {
        Args: {
          p_basic_salary: number
          p_contract_reference?: string
          p_effective_date: string
          p_employee_id: string
          p_note?: string
        }
        Returns: {
          basic_salary: number
          contract_reference: string | null
          created_at: string
          created_by: string
          currency: string
          effective_date: string
          employee_id: string
          id: string
          note: string | null
          tenant_id: string
        }
        SetofOptions: {
          from: "*"
          to: "hr_employee_compensation"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      record_goods_issue: {
        Args: {
          p_approved_by_name: string
          p_items: Json
          p_project_label: string
          p_received_by_name: string
          p_voucher_no: string
          p_warehouse_id: string
        }
        Returns: {
          approved_by_name: string | null
          created_at: string
          id: string
          issue_date: string
          project_label: string | null
          received_by_name: string | null
          tenant_id: string
          voucher_no: string | null
          warehouse_id: string
          warehouse_officer_id: string
        }
        SetofOptions: {
          from: "*"
          to: "goods_issues"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      record_invoice_approval_decision: {
        Args: {
          p_acting_on_behalf_of?: string
          p_comment?: string
          p_decision: string
          p_invoice_request_id: string
        }
        Returns: {
          out_invoice_request_id: string
          out_stage_id: string
          out_status: string
        }[]
      }
      record_line_item_receipt:
        | {
            Args: {
              p_line_item_id: string
              p_note?: string
              p_received_qty: number
            }
            Returns: {
              approved_at: string | null
              approved_by: string | null
              id: string
              line_item_id: string
              note: string | null
              received_at: string
              received_by: string
              received_qty: number
              voucher_no: string | null
              warehouse_id: string | null
            }
            SetofOptions: {
              from: "*"
              to: "line_item_receipts"
              isOneToOne: true
              isSetofReturn: false
            }
          }
        | {
            Args: {
              p_line_item_id: string
              p_note?: string
              p_received_qty: number
              p_voucher_no?: string
              p_warehouse_id: string
            }
            Returns: {
              approved_at: string | null
              approved_by: string | null
              id: string
              line_item_id: string
              note: string | null
              received_at: string
              received_by: string
              received_qty: number
              voucher_no: string | null
              warehouse_id: string | null
            }
            SetofOptions: {
              from: "*"
              to: "line_item_receipts"
              isOneToOne: true
              isSetofReturn: false
            }
          }
      record_po_pdf: {
        Args: { p_purchase_order_id: string; p_storage_path: string }
        Returns: undefined
      }
      record_ticket_approval: {
        Args: { p_decision: string; p_notes?: string; p_ticket_id: string }
        Returns: {
          approval_notes: string | null
          approval_status: string
          approved_at: string | null
          approved_by: string | null
          assignee_id: string | null
          category: string
          closed_at: string | null
          created_at: string
          department_id: string
          description: string
          id: string
          priority: string
          requester_id: string
          requires_approval: boolean
          resolution_notes: string | null
          resolved_at: string | null
          status: string
          subject: string
          tenant_id: string
          ticket_number: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "it_tickets"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      reject_all_material_request_items: {
        Args: { p_batch_id: string; p_message: string }
        Returns: {
          batch_id: string
          created_at: string
          decided_at: string | null
          decided_by: string | null
          description_en: string | null
          description_fr: string | null
          description_tr: string | null
          external_material_group_id: string | null
          id: string
          material_catalog_id: string | null
          material_group_id: string | null
          material_type_id: string | null
          name: string
          old_material_code: string | null
          rejection_message: string | null
          status: string
          tenant_id: string
          unit: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "material_request_items"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      reject_material_request_item: {
        Args: { p_item_id: string; p_message: string }
        Returns: {
          batch_id: string
          created_at: string
          decided_at: string | null
          decided_by: string | null
          description_en: string | null
          description_fr: string | null
          description_tr: string | null
          external_material_group_id: string | null
          id: string
          material_catalog_id: string | null
          material_group_id: string | null
          material_type_id: string | null
          name: string
          old_material_code: string | null
          rejection_message: string | null
          status: string
          tenant_id: string
          unit: string | null
        }
        SetofOptions: {
          from: "*"
          to: "material_request_items"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      reject_payroll_run: {
        Args: { p_reason: string; p_run_id: string }
        Returns: {
          amount_disbursed: number
          approved_at: string | null
          approved_by: string | null
          created_at: string
          id: string
          period: string
          prepared_by: string
          rejected_at: string | null
          rejected_by: string | null
          rejection_reason: string | null
          status: string
          submitted_at: string | null
          tenant_id: string
        }
        SetofOptions: {
          from: "*"
          to: "hr_payroll_runs"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      remove_group_member: {
        Args: { p_group_id: string; p_user_id: string }
        Returns: undefined
      }
      remove_support_team_member: {
        Args: { p_team_id: string; p_user_id: string }
        Returns: undefined
      }
      resolve_or_create_vendor_account: {
        Args: { p_tenant_id: string; p_vendor_name: string }
        Returns: string
      }
      return_asset: {
        Args: { p_assignment_id: string; p_notes?: string }
        Returns: {
          asset_id: string
          assigned_at: string
          assigned_by: string | null
          assigned_to: string
          id: string
          notes: string | null
          returned_at: string | null
          tenant_id: string
        }
        SetofOptions: {
          from: "*"
          to: "asset_assignments"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      revoke_invitation: {
        Args: { p_invitation_id: string }
        Returns: undefined
      }
      revoke_receipt_access: { Args: { p_user_id: string }; Returns: undefined }
      seed_tenant_defaults: {
        Args: { p_industry_template: string; p_tenant_id: string }
        Returns: undefined
      }
      set_tenant_modules: {
        Args: { p_modules: string[]; p_tenant_id: string }
        Returns: string[]
      }
      set_tenant_status: {
        Args: { p_status: string; p_tenant_id: string }
        Returns: {
          created_at: string
          created_by: string | null
          id: string
          industry_template: string
          name: string
          status: string
        }
        SetofOptions: {
          from: "*"
          to: "tenants"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      share_purchase_order: {
        Args: { p_purchase_order_id: string }
        Returns: {
          amount: number
          completed_at: string | null
          currency: string
          delivered_at: string | null
          generated_at: string
          generated_by: string
          id: string
          initial_po_number: string | null
          payment_conditions: string | null
          pdf_generated_at: string | null
          pdf_storage_path: string | null
          po_number: string
          project_sap_no: string | null
          request_id: string
          shared_with_supplier: boolean
          terms_of_delivery: string | null
          vendor_account_id: string | null
          vendor_name: string
        }
        SetofOptions: {
          from: "*"
          to: "purchase_orders"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      start_impersonation: {
        Args: { p_tenant_id: string }
        Returns: {
          ended_at: string | null
          id: string
          platform_admin_id: string
          started_at: string
          tenant_id: string
        }
        SetofOptions: {
          from: "*"
          to: "impersonation_sessions"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      submit_offers_for_approval: {
        Args: { p_request_id: string }
        Returns: {
          cost_center_id: string | null
          created_at: string
          current_stage_id: string | null
          delivery_date: string | null
          department_id: string
          id: string
          item_description: string
          mr_number: string
          organization_id: string | null
          quantity: number
          replaces_request_id: string | null
          requester_id: string
          status: string
          subcontractor: string | null
          tenant_id: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "requests"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      submit_payroll_run: {
        Args: { p_run_id: string }
        Returns: {
          amount_disbursed: number
          approved_at: string | null
          approved_by: string | null
          created_at: string
          id: string
          period: string
          prepared_by: string
          rejected_at: string | null
          rejected_by: string | null
          rejection_reason: string | null
          status: string
          submitted_at: string | null
          tenant_id: string
        }
        SetofOptions: {
          from: "*"
          to: "hr_payroll_runs"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      submit_request_with_line_items: {
        Args: {
          p_cost_center_id: string
          p_delivery_date: string
          p_item_description: string
          p_line_items: Json
          p_quantity: number
          p_subcontractor: string
        }
        Returns: string
      }
      supplier_invoice_outstanding: {
        Args: { p_invoice_id: string }
        Returns: number
      }
      supplier_invoice_payable_now: {
        Args: { p_invoice_id: string }
        Returns: number
      }
      supplier_invoice_receipt_cap: {
        Args: { p_invoice_id: string }
        Returns: number
      }
      try_complete_po: {
        Args: { p_purchase_order_id: string }
        Returns: undefined
      }
      unlink_ticket_from_problem: {
        Args: { p_problem_id: string; p_ticket_id: string }
        Returns: undefined
      }
      update_app_user: {
        Args: {
          p_department_id?: string
          p_is_platform_admin?: boolean
          p_role_title?: string
          p_user_id: string
        }
        Returns: {
          created_at: string
          department_id: string | null
          email: string
          id: string
          is_company_admin: boolean
          is_platform_admin: boolean
          name: string
          role_title: string | null
          tenant_id: string
        }
        SetofOptions: {
          from: "*"
          to: "app_users"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_asset: {
        Args: {
          p_asset_id: string
          p_category?: string
          p_name?: string
          p_notes?: string
          p_purchase_cost?: number
          p_serial_number?: string
          p_status?: string
          p_vendor?: string
        }
        Returns: {
          asset_tag: string | null
          category: string | null
          created_at: string
          id: string
          name: string
          notes: string | null
          purchase_cost: number | null
          purchase_date: string | null
          serial_number: string | null
          status: string
          tenant_id: string
          type: string
          updated_at: string
          vendor: string | null
        }
        SetofOptions: {
          from: "*"
          to: "assets"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_faq: {
        Args: {
          p_answer?: string
          p_category?: string
          p_faq_id: string
          p_is_published?: boolean
          p_question?: string
          p_sort_order?: number
        }
        Returns: {
          answer: string
          category: string | null
          created_at: string
          id: string
          is_published: boolean
          question: string
          sort_order: number
          tenant_id: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "faqs"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_kb_article: {
        Args: {
          p_article_id: string
          p_category?: string
          p_content?: string
          p_is_published?: boolean
          p_title?: string
        }
        Returns: {
          category: string | null
          content: string
          created_at: string
          created_by: string | null
          id: string
          is_published: boolean
          tenant_id: string
          title: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "kb_articles"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_license: {
        Args: {
          p_expiry_date?: string
          p_license_id: string
          p_license_key?: string
          p_notes?: string
          p_seats_total?: number
          p_vendor?: string
        }
        Returns: {
          asset_id: string
          created_at: string
          expiry_date: string | null
          id: string
          license_key: string | null
          notes: string | null
          seats_total: number
          tenant_id: string
          updated_at: string
          vendor: string | null
        }
        SetofOptions: {
          from: "*"
          to: "licenses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_payroll_item: {
        Args: {
          p_allowances: number
          p_deductions: number
          p_item_id: string
          p_note?: string
        }
        Returns: {
          allowances: number
          basic_salary: number
          deductions: number
          employee_id: string
          id: string
          net_pay: number | null
          note: string | null
          payroll_run_id: string
        }
        SetofOptions: {
          from: "*"
          to: "hr_payroll_items"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_priority_level: {
        Args: { p_code: string; p_color?: string; p_label?: string }
        Returns: {
          code: string
          color: string
          id: string
          label: string
          sort_order: number
          tenant_id: string
        }
        SetofOptions: {
          from: "*"
          to: "priority_levels"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_problem: {
        Args: {
          p_assigned_to?: string
          p_description?: string
          p_problem_id: string
          p_root_cause?: string
          p_status?: string
          p_title?: string
        }
        Returns: {
          assigned_to: string | null
          category: string | null
          closed_at: string | null
          created_at: string
          created_by: string | null
          description: string | null
          id: string
          priority: string
          problem_number: string | null
          resolved_at: string | null
          root_cause: string | null
          status: string
          tenant_id: string
          title: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "problems"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_support_team: {
        Args: {
          p_description?: string
          p_id: string
          p_is_active?: boolean
          p_name?: string
        }
        Returns: {
          created_at: string
          description: string | null
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        SetofOptions: {
          from: "*"
          to: "support_teams"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_ticket_category: {
        Args: { p_id: string; p_is_active?: boolean; p_name?: string }
        Returns: {
          code: string
          created_at: string
          id: string
          is_active: boolean
          name: string
          tenant_id: string
        }
        SetofOptions: {
          from: "*"
          to: "ticket_categories"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_ticket_status: {
        Args: {
          p_resolution_notes?: string
          p_status: string
          p_ticket_id: string
        }
        Returns: {
          approval_notes: string | null
          approval_status: string
          approved_at: string | null
          approved_by: string | null
          assignee_id: string | null
          category: string
          closed_at: string | null
          created_at: string
          department_id: string
          description: string
          id: string
          priority: string
          requester_id: string
          requires_approval: boolean
          resolution_notes: string | null
          resolved_at: string | null
          status: string
          subject: string
          tenant_id: string
          ticket_number: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "it_tickets"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_workflow_stage_threshold: {
        Args: { p_stage_id: string; p_threshold_amount: number }
        Returns: undefined
      }
      upsert_sla_policy: {
        Args: {
          p_description?: string
          p_priority: string
          p_target_hours: number
        }
        Returns: {
          description: string | null
          id: string
          priority: string
          target_hours: number
          tenant_id: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "sla_policies"
          isOneToOne: true
          isSetofReturn: false
        }
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const
