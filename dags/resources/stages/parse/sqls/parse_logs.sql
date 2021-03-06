CREATE TEMP FUNCTION
    PARSE_LOG(data STRING, topics ARRAY<STRING>)
    RETURNS STRUCT<{{params.struct_fields}}>
    LANGUAGE js AS """
    var abi = {{params.abi}}

    var interface_instance = new ethers.utils.Interface([abi]);

    var parsedLog = interface_instance.parseLog({topics: topics, data: data});

    var parsedValues = parsedLog.values;

    var transformParams = function(params, abiInputs) {
        var result = {};
        if (params && params.length >= abiInputs.length) {
            for (var i = 0; i < abiInputs.length; i++) {
                var paramName = abiInputs[i].name;
                var paramValue = params[i];
                if (abiInputs[i].type === 'address' && typeof paramValue === 'string') {
                    // For consistency all addresses are lower-cased.
                    paramValue = paramValue.toLowerCase();
                }
                if (ethers.utils.Interface.isIndexed(paramValue)) {
                    paramValue = paramValue.hash;
                }
                if (abiInputs[i].type === 'tuple' && 'components' in abiInputs[i]) {
                    paramValue = transformParams(paramValue, abiInputs[i].components)
                }
                result[paramName] = paramValue;
            }
        }
        return result;
    };

    var result = transformParams(parsedValues, abi.inputs);

    return result;
"""
OPTIONS
  ( library="gs://blockchain-etl-bigquery/ethers.js" );

WITH parsed_logs AS
(SELECT
    logs.block_timestamp AS block_timestamp
    ,logs.block_number AS block_number
    ,logs.transaction_hash AS transaction_hash
    ,logs.log_index AS log_index
    ,logs.address AS contract_address
    ,PARSE_LOG(logs.data, logs.topics) AS parsed
FROM `{{params.source_project_id}}.{{params.source_dataset_name}}.logs` AS logs
WHERE address in (
    {% if params.parser.contract_address_sql %}
    {{params.parser.contract_address_sql}}
    {% else %}
    '{{params.parser.contract_address}}'
    {% endif %}
  )
  AND topics[SAFE_OFFSET(0)] = '{{params.event_topic}}'
  {% if params.parse_all_partitions %}
  AND DATE(block_timestamp) <= '{{ds}}'
  {% else %}
  AND DATE(block_timestamp) = '{{ds}}'
  {% endif %}
  )
SELECT
     block_timestamp
     ,block_number
     ,transaction_hash
     ,log_index
     ,contract_address
     {% for column in params.columns %}
    ,parsed.{{ column }} AS `{{ column }}`{% endfor %}
FROM parsed_logs
