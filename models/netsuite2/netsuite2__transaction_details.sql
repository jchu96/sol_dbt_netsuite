{{ config(enabled=var('netsuite_data_model', 'netsuite') == var('netsuite_data_model_override','netsuite2')) }}

with transactions_with_converted_amounts as (
    select * 
    from {{ref('int_netsuite2__tran_with_converted_amounts')}}
),

accounts as (
    select * 
    from {{ ref('int_netsuite2__accounts') }}
),

accounting_periods as (
    select * 
    from {{ ref('int_netsuite2__accounting_periods') }}
),

subsidiaries as (
    select * 
    from {{ var('netsuite2_subsidiaries') }}
),

transaction_lines as (
    select * 
    from {{ ref('int_netsuite2__transaction_lines') }}
),

transactions as (
    select * 
    from {{ var('netsuite2_transactions') }}
),

customers as (
    select * 
    from {{ ref('int_netsuite2__customers') }}
),

items as (
    select * 
    from {{ var('netsuite2_items') }}
),

locations as (
    select * 
    from {{ ref('int_netsuite2__locations') }}
),

vendors as (
    select * 
    from {{ var('netsuite2_vendors') }}
),

{% if var('netsuite2__using_vendor_categories', true) %}
vendor_categories as (
    select * 
    from {{ var('netsuite2_vendor_categories') }}
),
{% endif %}

departments as (
    select * 
    from {{ var('netsuite2_departments') }}
),

currencies as (
    select * 
    from {{ var('netsuite2_currencies') }}
),

classes as (
    select *
    from {{ var('netsuite2_classes') }}
),

entities as (
    select *
    from {{ var('netsuite2_entities') }}
),

-- Soligent edit
transaction_status as (
SELECT id,
       name,
       trantype
FROM netsuite2.transactionstatus where _fivetran_deleted = 0),

entity_status as (
SELECT key,
       name
FROM netsuite2.entitystatus where _fivetran_deleted = 0),

created_from_query as (select transaction, createdfrom from
netsuite2.transactionline
where _fivetran_deleted = 0  and id = 0
group by transaction, createdfrom),

cost_estimate_query as (select id, costestimate from
netsuite2.item
where _fivetran_deleted = 0),

--end soligent edit

transaction_details as (
  select
    transaction_lines.transaction_line_id,
    transaction_lines.memo as transaction_memo,
    not transaction_lines.is_posting as is_transaction_non_posting,
    transactions.transaction_id,
    transaction_status.name as transaction_status,
    transactions.transaction_date,
    transactions.due_date_at as transaction_due_date,
    transactions.transaction_type as transaction_type,
    transactions.is_intercompany_adjustment as is_transaction_intercompany_adjustment

    --The below script allows for transactions table pass through columns.
    {{ fivetran_utils.persist_pass_through_columns('transactions_pass_through_columns', identifier='transactions') }}

    --The below script allows for transaction lines table pass through columns.
    {{ fivetran_utils.persist_pass_through_columns('transaction_lines_pass_through_columns', identifier='transaction_lines') }},

    accounting_periods.ending_at as accounting_period_ending,
    accounting_periods.name as accounting_period_name,
    accounting_periods.is_adjustment as is_accounting_period_adjustment,
    accounting_periods.is_closed as is_accounting_period_closed,
	-- soligent edits
	accounting_periods.accounting_period_id as accounting_period_id,
	--end soligent edit
    accounts.name as account_name,
    accounts.type_name as account_type_name,
    accounts.account_id as account_id,
    accounts.account_number

    --The below script allows for accounts table pass through columns.
    {{ fivetran_utils.persist_pass_through_columns('accounts_pass_through_columns', identifier='accounts') }},

    accounts.is_leftside as is_account_leftside,
    lower(accounts.type_name) like 'accounts payable%' as is_accounts_payable,
    lower(accounts.type_name) like 'accounts receivable%' as is_accounts_receivable,
    lower(accounts.name) like '%intercompany%' as is_account_intercompany,
    coalesce(parent_account.name, accounts.name) as parent_account_name,
    lower(accounts.type_name) like '%expense' as is_expense_account, -- includes deferred expense
    lower(accounts.type_name) like '%income' as is_income_account,
    customers.company_name,
    customers.city as customer_city,
    customers.state as customer_state,
    customers.zipcode as customer_zipcode,
    customers.country as customer_country,
    customers.date_first_order_at as customer_date_first_order,
    customers.customer_external_id,
    classes.full_name as class_full_name,
    items.name as item_name,
    items.type_name as item_type_name,
    -- items.sales_description, --Soligent edit, removing this line 
	--edits from soligent
	items.item_id,
	items.item_classification_legacy,
	-- end edits
    locations.name as location_name,
    locations.city as location_city,
    locations.country as location_country,
	-- edits from Soligent
	locations.location_id,
	locations.location_description,
	entity_status.name as trans_quote_status,
	created_from_query.createdfrom,
	coalesce(cost_estimate_query.costestimate, 0) as item_costestimate,
	-- end edits
    {% if var('netsuite2__using_vendor_categories', true) %}
    vendor_categories.name as vendor_category_name,
    {% endif %}
    vendors.company_name as vendor_name,
    vendors.create_date_at as vendor_create_date,
    currencies.name as currency_name,
    currencies.symbol as currency_symbol,
    departments.name as department_name

    --The below script allows for departments table pass through columns.
    {{ fivetran_utils.persist_pass_through_columns('departments_pass_through_columns', identifier='departments') }},

    subsidiaries.name as subsidiary_name,
    case
      when lower(accounts.type_name) = 'income' or lower(accounts.type_name) = 'other income' then -converted_amount_using_transaction_accounting_period
      else converted_amount_using_transaction_accounting_period
        end as converted_amount,
    case
      when lower(accounts.type_name) = 'income' or lower(accounts.type_name) = 'other income' then -transaction_lines.amount
      else transaction_lines.amount
        end as transaction_amount,
	transactions.entity_id as transaction_entity_id
  from transaction_lines

  join transactions
    on transactions.transaction_id = transaction_lines.transaction_id

  left join transactions_with_converted_amounts as transactions_with_converted_amounts
    on transactions_with_converted_amounts.transaction_line_id = transaction_lines.transaction_line_id
      and transactions_with_converted_amounts.transaction_id = transaction_lines.transaction_id
      and transactions_with_converted_amounts.transaction_accounting_period_id = transactions_with_converted_amounts.reporting_accounting_period_id

  left join accounts 
    on accounts.account_id = transaction_lines.account_id

  left join accounts as parent_account 
    on parent_account.account_id = accounts.parent_id

  left join accounting_periods 
    on accounting_periods.accounting_period_id = transactions.accounting_period_id

  left join customers 
    on customers.customer_id = coalesce(transaction_lines.entity_id, transactions.entity_id)
  
  left join classes
    on classes.class_id = transaction_lines.class_id

  left join items 
    on items.item_id = transaction_lines.item_id

  left join locations 
    on locations.location_id = transaction_lines.location_id

  left join vendors 
    on vendors.vendor_id = coalesce(transaction_lines.entity_id, transactions.entity_id)

  {% if var('netsuite2__using_vendor_categories', true) %}
  left join vendor_categories 
    on vendor_categories.vendor_category_id = vendors.vendor_category_id
  {% endif %}

  left join currencies 
    on currencies.currency_id = transactions.currency_id

  left join departments 
    on departments.department_id = transaction_lines.department_id

  join subsidiaries 
    on subsidiaries.subsidiary_id = transaction_lines.subsidiary_id
	
--soligent edit
	left join transaction_status
	on transaction_status.id = transactions.status and transaction_status.trantype = transactions.transaction_type
	
	left join entity_status
	on entity_status.key = transactions.trans_quote_status_id
	
	left join created_from_query 
	on created_from_query.transaction = transactions.transaction_id
	
	left join cost_estimate_query
	on cost_estimate_query.id = transaction_lines.item_id
	
--end soligent edit    
  where (accounting_periods.fiscal_calendar_id is null
    or accounting_periods.fiscal_calendar_id  = (select fiscal_calendar_id from subsidiaries where parent_id is null))
)

select *
from transaction_details