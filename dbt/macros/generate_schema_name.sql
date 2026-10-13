{#
    dbt's default `generate_schema_name` returns `<profile_schema>_<custom_schema>`,
    so `+schema: silver` under a profile whose schema is already `silver` produced
    `silver_silver`, and `+schema: gold` produced `silver_gold`. Both tables were
    created, both queries worked, and the namespaces in Polaris were wrong.

    That default exists so several developers can share a warehouse without
    colliding. A lakehouse whose layer names are the contract does not want it:
    `bronze`, `silver`, `gold` are the point, and a bare `+schema` should mean
    exactly what it says.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
