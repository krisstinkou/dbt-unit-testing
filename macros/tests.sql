{% macro test(model_name, test_description, options={}) %}
  {{ dbt_unit_testing.ref_tested_model(model_name) }}
  {{ dbt_unit_testing._test(model_name, test_description, caller(), options)}}
{% endmacro %}

{% macro ref_tested_model(model_name) %}
  {%- set ref_tested_model -%}
    -- We add an (unused) reference to the tested model,
    -- so that DBT includes the model as a dependency of the test in the DAG
    select * from {{ ref(model_name) }}
  {%- endset -%}
{% endmacro %}

{% macro _test(model_name, test_description, test_info, options={}) %}
    {%- set test_description = test_description | default('(no description)') -%}
    {%- set test_info = test_info | trim -%}
    {%- set test_info_last_comma_removed = test_info[:-1] -%}
    {%- set test_info_json = fromjson('{' ~ test_info_last_comma_removed ~ '}') -%}

    {%- for k, v in test_info_json.items() -%}
      {%- set dummy = test_info_json.update({k: dbt_unit_testing.sql_decode(v)}) -%}
    {%- endfor -%}

    {%- set expectations = test_info_json['__EXPECTATIONS__'] -%}
    {%- set dummy = test_info_json.pop('__EXPECTATIONS__') -%}

    {{ dbt_unit_testing.run_test(model_name, test_description, test_info_json, expectations, options)}}
{% endmacro %}

{% macro ref(model_name) %}
  {%- if 'unit-test' in config.get('tags') -%}
      {{ dbt_unit_testing.quote_identifier(model_name) }}
  {%- else -%}
      {{ return (builtins.ref(model_name)) }}
  {%- endif -%}
{% endmacro %}

{% macro source(source, model_name) %}
  {%- if 'unit-test' in config.get('tags') -%}
      {{ dbt_unit_testing.quote_identifier(source ~ "__" ~ model_name) }}
  {%- else -%}
      {{ return (builtins.source(source, model_name)) }}
  {%- endif -%}
{% endmacro %}

{% macro expect(options={}) %}
    {%- set model_sql = dbt_unit_testing.build_input_values_sql(caller(), options) -%}
    {%- set input_as_json = '"__EXPECTATIONS__": "' ~ dbt_unit_testing.sql_encode(model_sql) ~ '",' -%}
    {{ return (input_as_json) }}
{% endmacro %}

{% macro run_test(model_name, test_description, mocked_models, expectations, options) %}
  {{ dbt_unit_testing.debug("DBT Unit Testing run test parsing: " ~ model_name) }}
  {%- set hide_errors = options.get("hide_errors", false) -%}
  {%- set mocking_strategy = dbt_unit_testing.get_mocking_strategy(options) -%}

  {%- set model_node = dbt_unit_testing.model_node(model_name) -%}
  {%- set sql_options = { "fetch_mode": 'DATABASE' if mocking_strategy.database else 'RAW',
                         "include_all_dependencies": mocking_strategy.full } -%}

  {%- set model_complete_sql = dbt_unit_testing.build_model_complete_sql(model_node, mocked_models, sql_options) -%}
  {%- set columns = dbt_unit_testing.quote_and_join_columns(dbt_unit_testing.extract_columns_list(expectations)) -%}

  {%- set actual_query -%}
    select {{columns}} from ( {{ model_complete_sql }} ) as s
  {% endset %}

  {%- set expectations_query -%}
    select {{columns}} from ({{ expectations }}) as s
  {% endset %}

  {%- set test_query -%}
    with expectations as (
      {{ expectations_query }}
    ),
    actual as (
      {{ actual_query }}
    ),

    extra_entries as (
    select '+' as diff, {{columns}} from actual
    {{ dbt_utils.except() }}
    select '+' as diff, {{columns}} from expectations),

    missing_entries as (
    select '-' as diff, {{columns}} from expectations
    {{ dbt_utils.except() }}
    select '-' as diff, {{columns}} from actual)
    
    select * from extra_entries
    UNION ALL
    select * from missing_entries
    {% set sort_field = options.get("output_sort_field") %}
    {% if sort_field %}
    ORDER BY {{ sort_field }}
    {% endif %}
  {%- endset -%}

  {%- if execute and flags.WHICH == 'test' -%}
    {%- if var('debug', false) or dbt_unit_testing.get_config('debug', false) -%}
      {{ dbt_unit_testing.debug("------------------------------------") }}
      {{ dbt_unit_testing.debug("MODEL: " ~ model_name) }}
      {{ dbt_unit_testing.debug(test_query) }}
    {%- endif -%}
    {%- set test_full_name = model_name ~ '-' ~ modules.re.sub("[^-_a-zA-Z0-9]", "_", test_description) -%}
    {%- set compiled_file = 'unit_testing/compiled/' ~ test_full_name ~ '.sql' -%}
    {%- set compiled_test_sql_file = save_content_to_cache(compiled_file, test_query) -%}
    {%- do log('Compiled Test SQL file: ' ~ compiled_test_sql_file, info=true) -%}

    {%- set count_query -%}
      select * FROM (select count(1) as expectation_count from (
          {{ expectations_query }}
        ) as exp) as exp_count, (select count(1) as actual_count from (
          {{ actual_query }}
        ) as act) as act_count
    {%- endset -%}
    {%- set r1 = run_query(count_query) -%}
    {%- set expectations_row_count = r1.columns[0].values() | first -%}
    {%- set actual_row_count = r1.columns[1].values() | first -%}

    {%- set results = run_query(test_query) -%}
    {%- set results_length = results.rows | length -%}
    {%- set failed = results_length > 0 or expectations_row_count != actual_row_count -%}

    {%- if failed and not hide_errors -%}
      {%- do log('\x1b[31m' ~ 'MODEL: ' ~ model_name ~ '\x1b[0m', info=true) -%}
      {%- do log('\x1b[31m' ~ 'TEST:  ' ~ test_description ~ '\x1b[0m', info=true) -%}
      
      {% if expectations_row_count != actual_row_count %}
        {%- do log('\x1b[31m' ~ 'Number of Rows do not match! (Expected: ' ~ expectations_row_count ~ ', Actual: ' ~ actual_row_count ~ ')' ~ '\x1b[0m', info=true) -%}
      {%- endif -%}
      {% if results_length > 0 %}
        {%- do log('\x1b[31m' ~ 'Rows mismatch:' ~ '\x1b[0m', info=true) -%}
        {%- do results.print_table(max_columns=None, max_column_width=30) -%}

        {%- set report_file = 'target/unit_testing/failures/' ~ test_full_name -%}
        {%- set csv_report_file = report_file ~ '.csv' -%}
        {%- set json_report_file = report_file ~ '.json' -%}
        {%- do log('\x1b[31m' ~ 'Compiled Test SQL file:  ' ~ compiled_test_sql_file ~ '\x1b[0m', info=true) -%}
        {%- if dbt_unit_testing.get_config('generate_fail_report_in_csv', false) -%}
          {%- do results.to_csv(csv_report_file) -%}
          {%- do log('\x1b[31m' ~ 'CSV REPORT FILE:  ' ~ csv_report_file ~ '\x1b[0m', info=true) -%}
        {%- endif -%}
        {%- if dbt_unit_testing.get_config('generate_fail_report_in_json', false) -%}
          {%- do results.to_json(json_report_file, indent=4) -%}
          {%- do log('\x1b[31m' ~ 'JSON REPORT FILE:  ' ~ json_report_file ~ '\x1b[0m', info=true) -%}
        {%- endif -%}
      {%- endif -%}
    {%- endif -%}
    (
      with test_query as (
        {{ test_query }}
      )
      select 1 from (select 1) as t where {{ failed }}
    )
  {%- endif -%}
{%- endmacro -%}
