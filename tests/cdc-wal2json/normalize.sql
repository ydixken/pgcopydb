.bail on
create temp table input (
    data text not null check (json_type(data) = 'array' and json_array_length(data) > 0)
);
insert into input values (readfile(@input));

with records as (
    select key as id, json_extract(value, '$.action') as action,
           json_extract(value, '$.message') as message
      from input, json_each(input.data)
), xids as (
    select json_extract(message, '$.xid') as xid,
           dense_rank() over (order by min(id)) as ordinal
      from records
     where json_type(message, '$.xid') = 'integer'
     group by json_extract(message, '$.xid')
)
select action,
       case when json_type(message, '$.xid') = 'integer'
            then json_replace(message, '$.xid', ordinal)
            else json(message)
        end as message
  from records left join xids on json_extract(message, '$.xid') = xids.xid
 order by id;
