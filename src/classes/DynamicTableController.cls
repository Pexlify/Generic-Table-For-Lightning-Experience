public class DynamicTableController {

    private static final Integer MAX_QUERY_RECORDS = 2000;

    @AuraEnabled
    public static String getColumnMetadata(String sobject_name, List<String> field_names, List<String> field_labels, List<String> sortable_field_names, List<String> reference_fields, List<String> override_field_type){
        return JSON.serialize(new ColumnMetadataWrapper(sobject_name, field_names, field_labels, sortable_field_names, reference_fields, override_field_type), true);
    }

    @AuraEnabled
    public static Integer getTotalRecords(String sobject_name, String match_criteria){
        String query = 'SELECT COUNT() FROM ' + String.escapeSingleQuotes(sobject_name);
        if(String.isNotBlank(match_criteria)){
            query += ' WHERE ' + match_criteria;
        }
        return Database.countQuery(query);
    }

    @AuraEnabled
    public static String getRecords(String sobject_name, List<String> field_names, String match_criteria, String sort_by_field, String sort_order){
        String query = 'SELECT ' + String.escapeSingleQuotes(String.join(field_names, ',')) + ' FROM ' + String.escapeSingleQuotes(sobject_name);
        if(String.isNotBlank(match_criteria)){
            query += ' WHERE ' + match_criteria;
        }
        if(String.isNotBlank(sort_by_field)){
            query += ' ORDER BY ' + String.escapeSingleQuotes(sort_by_field) + ' ' + String.escapeSingleQuotes(sort_order);
            if(sort_order == 'ASC'){
                query += ' NULLS FIRST';
            } else {
                query += ' NULLS LAST';
            }
        }
        query += ' LIMIT ' + String.valueOf(MAX_QUERY_RECORDS);
        List<SObject> sobjects = new List<SObject>();
        try {
            sobjects = Database.query(query);
        } catch(QueryException e){
            return JSON.serialize(new SObjectWrapper(e.getMessage()));
        }
        return JSON.serialize(new SObjectWrapper(sobjects));
    }

    private class ColumnMetadataWrapper {
        private Map<String, ColumnMetadata> column_metadata;
        private String error_message;

        public ColumnMetadataWrapper(String sobject_name, List<String> field_names, List<String> field_labels, List<String> sortable_field_names, List<String> reference_fields, List<String> override_field_type){
            String namespace = retrieveNamespace();
            try {
                String sobject_internal_name = parseSObjectName(namespace, sobject_name);
                if(!Schema.getGlobalDescribe().get(sobject_internal_name).getDescribe().isAccessible()){
                    throw new DynamicTableController.DynamicTableException('User doesn\'t have access to object: ' + Schema.getGlobalDescribe().get(sobject_internal_name).getDescribe().getName() + '.');
                }
                parseFieldsString(namespace, sobject_internal_name, field_names);
                setColumnsLabels(field_labels);
                setSortableColumns(sortable_field_names);
                setReferenceColumns(reference_fields);
                setOverridedFieldTypeColumns(override_field_type);
            } catch (DynamicTableException e){
                error_message = e.getMessage();
                column_metadata = new Map<String, ColumnMetadata>();
            }
        }

        private String retrieveNamespace(){
            String class_name = DynamicTableController.class.getName();
            if(class_name.countMatches('.') == 1){
                return class_name.substringBefore('.') + '__';
            }
            return '';
        }

        private String parseSObjectName(String namespace, String sobject_name){
            if(Schema.getGlobalDescribe().containsKey(sobject_name)){
                return sobject_name;
            } else if(String.isNotBlank(namespace) && Schema.getGlobalDescribe().containsKey(namespace + sobject_name)){
                return namespace + sobject_name;
            } else {
                throw new DynamicTableException('Unknown SObject: ' + sobject_name + '.');
            }
        }

        private void parseFieldsString(String namespace, String sobject_internal_name, List<String> field_names){
            column_metadata = new Map<String, ColumnMetadata>();
            for(String field_name : field_names){
                column_metadata.put(field_name, new ColumnMetadata(namespace, sobject_internal_name, field_name));
            }
        }

        private void setColumnsLabels(List<String> field_labels){
            for(String unconverted_field_label : field_labels){
                String field_name = unconverted_field_label.substringBefore(':');
                String field_label = unconverted_field_label.substringAfter(':');
                if(!column_metadata.containsKey(field_name)){
                    throw new DynamicTableException('Unknown field in label string: ' + field_name + '.');
                }
                column_metadata.get(field_name).setFieldLabel(field_label);
            }
        }

        private void setSortableColumns(List<String> sortable_field_names){
            if(!sortable_field_names.isEmpty()){
                for(String field_name : sortable_field_names){
                    if(!column_metadata.containsKey(field_name)){
                        throw new DynamicTableException('Unknown field in sortable string: ' + field_name + '.');
                    }
                    column_metadata.get(field_name).setFieldIsSortable(true);
                }
            } else {
                for(ColumnMetadata column : column_metadata.values()){
                    column.setFieldIsSortable(true);
                }
            }
        }

        private void setReferenceColumns(List<String> reference_fields){
            for(String field_name : reference_fields){
                if(!column_metadata.containsKey(field_name)){
                    throw new DynamicTableException('Unknown field in reference string: ' + field_name + '.');
                }
                column_metadata.get(field_name).setFieldIsReference(true);
            }
        }

        private void setOverridedFieldTypeColumns(List<String> override_field_type){
            for(String unconverted_field_label : override_field_type){
                String field_name = unconverted_field_label.substringBefore(':');
                String field_type = unconverted_field_label.substringAfter(':');
                if(!column_metadata.containsKey(field_name)){
                    throw new DynamicTableException('Unknown field in override field type string: ' + field_name + '.');
                }
                column_metadata.get(field_name).setFieldOverrideType(field_type);
            }
        }

    }

    private class ColumnMetadata {
        private String field_api_name;
        private String field_label;
        private String field_type;
        private String field_override_type;
        private Boolean field_is_reference;
        private Boolean field_is_sortable;

        public ColumnMetadata(String namespace, String sobject_internal_name, String field_name){
            Map<String, Schema.SObjectField> sobject_fields = Schema.getGlobalDescribe().get(sobject_internal_name).getDescribe().fields.getMap();
            List<String> relationship = field_name.split('\\.');
            if(relationship.size() > 1){
                populateRelationshipFieldDescribe(namespace, relationship, sobject_fields);
            } else {
                populateValueFieldDescribe(namespace, relationship[0], sobject_fields);
            }
            field_override_type = null;
            field_is_reference = false;
            field_is_sortable = false;
        }

        public void setFieldLabel(String label){
            field_label = label;
        }

        public void setFieldIsSortable(Boolean is_sortable){
            field_is_sortable = is_sortable;
        }

        public void setFieldIsReference(Boolean is_reference){
            field_is_reference = is_reference;
        }

        public void setFieldOverrideType(String override_type){
            field_override_type = override_type;
        }

        private void populateRelationshipFieldDescribe(String namespace, List<String> relationship, Map<String, SObjectField> sobject_fields){
            DescribeFieldResult describe_field_result;
            String field_name = getRelationshipField(relationship[0]);
            relationship.remove(0);
            if(sobject_fields.containsKey(field_name)){
                describe_field_result = sobject_fields.get(field_name).getDescribe();
            } else if(String.isNotBlank(namespace) && sobject_fields.containsKey(namespace + field_name)){
                describe_field_result = sobject_fields.get(namespace + field_name).getDescribe();
            } else {
                throw new DynamicTableException('Unknown relationship: ' + relationship[0] + '.');
            }
            if(!describe_field_result.isAccessible()){
                throw new DynamicTableException('User doesn\'t have access to field: ' + describe_field_result.getName() + '.');
            }
            if(field_api_name != null){
                field_api_name += '.' + describe_field_result.getRelationshipName();
            } else {
                field_api_name = describe_field_result.getRelationshipName();
            }
            if(relationship.size() > 1){
                populateRelationshipFieldDescribe(namespace, relationship, Schema.getGlobalDescribe().get(describe_field_result.getReferenceTo().get(0).getDescribe().getName()).getDescribe().fields.getMap());
            } else {
                populateValueFieldDescribe(namespace, relationship[0], Schema.getGlobalDescribe().get(describe_field_result.getReferenceTo().get(0).getDescribe().getName()).getDescribe().fields.getMap());
            }
        }

        private String getRelationshipField(String field_name){
            return field_name.endsWith('__r') ? field_name.replace('__r', '__c') : field_name + 'Id';
        }

        private void populateValueFieldDescribe(String namespace, String field_name, Map<String, SObjectField> sobject_fields){
            DescribeFieldResult describe_field_result;
            if(sobject_fields.containsKey(field_name)){
                describe_field_result = sobject_fields.get(field_name).getDescribe();
            } else if(String.isNotBlank(namespace) && sobject_fields.containsKey(namespace + field_name)){
                describe_field_result = sobject_fields.get(namespace + field_name).getDescribe();
            } else {
                throw new DynamicTableException('Unknown field: ' + field_name + '.');
            }
            if(!describe_field_result.isAccessible()){
                throw new DynamicTableController.DynamicTableException('User doesn\'t have access to field: ' + describe_field_result.getName() + '.');
            }
            if(field_api_name != null){
                field_api_name += '.' + describe_field_result.getName();
            } else {
                field_api_name = describe_field_result.getName();
            }
            field_label =  describe_field_result.getLabel();
            field_type = describe_field_result.getType().name();
        }

    }

    private class SObjectWrapper {
        String error_message;
        List<SObject> sobjects;

        public SObjectWrapper(String message){
            error_message = message;
            sobjects = new List<SObject>();
        }

        public SObjectWrapper(List<SObject> queried_sobjects){
            sobjects = queried_sobjects;
        }
    }

    private class DynamicTableException extends Exception {}

}