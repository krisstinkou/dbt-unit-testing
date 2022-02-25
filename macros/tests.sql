{% macro test(model_name, test_description) %}
    {% set test_description = test_description | default('(no description)') %}
    {% set test_info = caller() | trim %}
    {% set test_info_last_comma_removed = test_info[:-1] %}
    {% set test_info_json = fromjson('{' ~ test_info_last_comma_removed ~ '}') %}

    {% for k, v in test_info_json.items() %}
      {% set dummy = test_info_json.update({k: dbt_unit_testing.sql_decode(v)}) %}
    {% endfor %}
    
    {% set expectations = test_info_json['__EXPECTATIONS__'] %}
    {% set dummy = test_info_json.pop('__EXPECTATIONS__') %}

    {{ dbt_unit_testing.run_test(model_name, test_description, test_info_json, expectations)}}
{% endmacro %}

{% macro ref(model_name) %}
{%- if 'unit-test' in config.get('tags') -%}
    {{model_name}}
{%- else -%}
    {{ return (builtins.ref(model_name)) }}
{%- endif -%}
{% endmacro %}

{% macro source(source, model_name) %}
{%- if 'unit-test' in config.get('tags') -%}
    {{model_name}}
{%- else -%}
    {{ return (builtins.source(source, model_name)) }}
{%- endif -%}
{% endmacro %}

{% macro build_input_values_sql(input_values, options) %}
    {% set unit_tests_config = var("unit_tests_config", {}) %}
    {% set input_format = options.get("input_format", unit_tests_config.get("input_format", "sql")) %}

    {% set input_values_sql = input_values %}

    {% if input_format == "csv" %}
      {% set input_values_sql = dbt_unit_testing.sql_from_csv_input(input_values, options) %}
    {%- endif -%}

    {{ return (input_values_sql) }}
{% endmacro %}

{% macro mock_ref(model_name, options={}) %}
    {{ dbt_unit_testing.mock_input(model_name, '', caller(), options) }}
{% endmacro %}

{% macro mock_source(source_name, model_name, options={}) %}
    {{ dbt_unit_testing.mock_input(model_name, source_name, caller(), options) }}
{% endmacro %}

{% macro mock_input(model_name, source_name, input_values, options) %}

  {% if execute %}
    {% set input_values_sql = dbt_unit_testing.build_input_values_sql(input_values, options) %}

    {%- set model_sql -%}
      {%if source_name %}
        {% set node = dbt_unit_testing.source_node(source_name, model_name) %}
        {% set model_columns = dbt_unit_testing.source_columns(node) %}
      {% else %}
        {% set model_complete_sql = dbt_unit_testing.build_model_complete_sql(model_name, [], include_sources = true) %}
        {% set model_columns = dbt_unit_testing.extract_columns_list(model_complete_sql) %}
      {% endif %}

      {% set input_columns = dbt_unit_testing.extract_columns_list(input_values_sql) %}
      {% set extra_columns = dbt_unit_testing.extract_columns_difference(model_columns | list, input_columns | list) %}
      {% set extra_columns_as_null = dbt_unit_testing.map(extra_columns, dbt_unit_testing.set_as_null) %}
      {% set all_columns = ["*"] + extra_columns_as_null %}

      select {{ all_columns | join(",") }}
      from ({{ input_values_sql }}) as {{model_name}}_tmp
    {%- endset -%}

    {%- set input_as_json = '"' ~ model_name  ~ '": "' ~ dbt_unit_testing.sql_encode(model_sql) ~ '",' -%}
    {{ return (input_as_json) }}
  {% endif %}
{% endmacro %}

{%- macro set_as_null(column) -%}
  null as {{ column }}
{%- endmacro -%}

{% macro expect(options={}) %}
    {%- set model_sql = dbt_unit_testing.build_input_values_sql(caller(), options) -%}
    {%- set input_as_json = '"__EXPECTATIONS__": "' ~ dbt_unit_testing.sql_encode(model_sql) ~ '",' -%}
    {{ return (input_as_json) }}
{% endmacro %}

{% macro run_test(model_name, test_description, test_inputs, expectations) %}
  {% set test_inputs_models = test_inputs.keys() | list %}
  {% set model_complete_sql = dbt_unit_testing.build_model_complete_sql(model_name, test_inputs_models) %}
  {% set columns = dbt_unit_testing.extract_columns_list(expectations) %}
  {% set columns = dbt_unit_testing.map(columns, adapter.quote) | join(",") %}

  {%- set sql_for_running_test -%}
    {% for m, m_sql in test_inputs.items() %}
      {%- if loop.first -%} {{ 'with ' }} {%- endif -%}
      {{ m }} as ({{ dbt_unit_testing.sql_decode(m_sql) }}),
    {% endfor %}
  
    expectations as (select {{columns}}, count(*) as count from ({{ expectations }}) as s group by {{columns}}),

    actual as (select {{columns}}, count(*) as count from ( {{ model_complete_sql }} ) as s group by {{columns}}),

    extra_entries as (
    select '+' as diff, count, {{columns}} from actual 
    {{ dbt_unit_testing.sql_except() }}
    select '+' as diff, count, {{columns}} from expectations),

    missing_entries as (
    select '-' as diff, count, {{columns}} from expectations
    {{ dbt_unit_testing.sql_except() }}
    select '-' as diff, count, {{columns}} from actual)
    
    select * from extra_entries
    UNION ALL 
    select * from missing_entries
  {% endset %}

  {% if execute %}
    {% set results = run_query(sql_for_running_test) %}
    {% set results_length = results.rows|length %}
    {% if results_length > 0 %}
      {%- do log('\x1b[31m' ~ 'MODEL: ' ~ model_name ~ '\x1b[0m', info=true) -%}
      {%- do log('\x1b[31m' ~ 'TEST:  ' ~ test_description ~ '\x1b[0m', info=true) -%}
      {% do results.print_table(max_columns=None, max_column_width=30) %}
    {% endif %}
    select 1 from (select 1) as t where {{ results_length }} != 0    
  {% endif %}
{% endmacro %}
