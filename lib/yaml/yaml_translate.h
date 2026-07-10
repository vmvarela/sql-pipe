/*
 * Minimal yaml.h subset for Zig translateC.
 *
 * Contains ONLY the types and functions used by src/yaml.zig.
 * NO system headers included — avoids MSVC wcscat_s, NetBSD #pragma GCC visibility,
 * and other translator-hostile constructs.
 *
 * Source: libyaml 0.2.5 include/yaml.h — copied verbatim for ABI compatibility.
 */

#ifndef YAML_TRANSLATE_H
#define YAML_TRANSLATE_H

/* Basic types — use built-in C types, no stddef.h needed */
typedef unsigned char yaml_char_t;
typedef unsigned long size_t;

/* Version directives */
typedef struct yaml_version_directive_s {
    int major;
    int minor;
} yaml_version_directive_t;

/* Tag directives */
typedef struct yaml_tag_directive_s {
    yaml_char_t *handle;
    yaml_char_t *prefix;
} yaml_tag_directive_t;

/* Encoding */
typedef enum yaml_encoding_e {
    YAML_ANY_ENCODING,
    YAML_UTF8_ENCODING,
    YAML_UTF16LE_ENCODING,
    YAML_UTF16BE_ENCODING
} yaml_encoding_t;

/* Line breaks */
typedef enum yaml_break_e {
    YAML_ANY_BREAK,
    YAML_CR_BREAK,
    YAML_LN_BREAK,
    YAML_CRLN_BREAK
} yaml_break_t;

/* Error types */
typedef enum yaml_error_type_e {
    YAML_NO_ERROR,
    YAML_MEMORY_ERROR,
    YAML_READER_ERROR,
    YAML_SCANNER_ERROR,
    YAML_PARSER_ERROR,
    YAML_COMPOSER_ERROR,
    YAML_WRITER_ERROR,
    YAML_EMITTER_ERROR
} yaml_error_type_t;

/* Mark (position) */
typedef struct yaml_mark_s {
    size_t index;
    size_t line;
    size_t column;
} yaml_mark_t;

/* Scalar styles */
typedef enum yaml_scalar_style_e {
    YAML_ANY_SCALAR_STYLE,
    YAML_PLAIN_SCALAR_STYLE,
    YAML_SINGLE_QUOTED_SCALAR_STYLE,
    YAML_DOUBLE_QUOTED_SCALAR_STYLE,
    YAML_LITERAL_SCALAR_STYLE,
    YAML_FOLDED_SCALAR_STYLE
} yaml_scalar_style_t;

/* Sequence styles */
typedef enum yaml_sequence_style_e {
    YAML_ANY_SEQUENCE_STYLE,
    YAML_BLOCK_SEQUENCE_STYLE,
    YAML_FLOW_SEQUENCE_STYLE
} yaml_sequence_style_t;

/* Mapping styles */
typedef enum yaml_mapping_style_e {
    YAML_ANY_MAPPING_STYLE,
    YAML_BLOCK_MAPPING_STYLE,
    YAML_FLOW_MAPPING_STYLE
} yaml_mapping_style_t;

/* Token types */
typedef enum yaml_token_type_e {
    YAML_NO_TOKEN,
    YAML_STREAM_START_TOKEN,
    YAML_STREAM_END_TOKEN,
    YAML_VERSION_DIRECTIVE_TOKEN,
    YAML_TAG_DIRECTIVE_TOKEN,
    YAML_DOCUMENT_START_TOKEN,
    YAML_DOCUMENT_END_TOKEN,
    YAML_BLOCK_SEQUENCE_START_TOKEN,
    YAML_BLOCK_MAPPING_START_TOKEN,
    YAML_BLOCK_END_TOKEN,
    YAML_FLOW_SEQUENCE_START_TOKEN,
    YAML_FLOW_SEQUENCE_END_TOKEN,
    YAML_FLOW_MAPPING_START_TOKEN,
    YAML_FLOW_MAPPING_END_TOKEN,
    YAML_BLOCK_ENTRY_TOKEN,
    YAML_FLOW_ENTRY_TOKEN,
    YAML_KEY_TOKEN,
    YAML_VALUE_TOKEN,
    YAML_ALIAS_TOKEN,
    YAML_ANCHOR_TOKEN,
    YAML_TAG_TOKEN,
    YAML_SCALAR_TOKEN
} yaml_token_type_t;

/* Token structure */
typedef struct yaml_token_s {
    yaml_token_type_t type;
    union {
        struct { yaml_encoding_t encoding; } stream_start;
        struct { yaml_char_t *value; } alias;
        struct { yaml_char_t *value; } anchor;
        struct { yaml_char_t *handle; yaml_char_t *suffix; } tag;
        struct { yaml_char_t *value; size_t length; yaml_scalar_style_t style; } scalar;
        struct { int major; int minor; } version_directive;
        struct { yaml_char_t *handle; yaml_char_t *prefix; } tag_directive;
    } data;
    yaml_mark_t start_mark;
    yaml_mark_t end_mark;
} yaml_token_t;

/* Event types */
typedef enum yaml_event_type_e {
    YAML_NO_EVENT,
    YAML_STREAM_START_EVENT,
    YAML_STREAM_END_EVENT,
    YAML_DOCUMENT_START_EVENT,
    YAML_DOCUMENT_END_EVENT,
    YAML_ALIAS_EVENT,
    YAML_SCALAR_EVENT,
    YAML_SEQUENCE_START_EVENT,
    YAML_SEQUENCE_END_EVENT,
    YAML_MAPPING_START_EVENT,
    YAML_MAPPING_END_EVENT
} yaml_event_type_t;

/* Event structure */
typedef struct yaml_event_s {
    yaml_event_type_t type;
    union {
        struct { yaml_encoding_t encoding; } stream_start;
        struct {
            yaml_version_directive_t *version_directive;
            struct { yaml_tag_directive_t *start; yaml_tag_directive_t *end; } tag_directives;
            int implicit;
        } document_start;
        struct { int implicit; } document_end;
        struct { yaml_char_t *anchor; } alias;
        struct {
            yaml_char_t *anchor;
            yaml_char_t *tag;
            yaml_char_t *value;
            size_t length;
            int plain_implicit;
            int quoted_implicit;
            yaml_scalar_style_t style;
        } scalar;
        struct {
            yaml_char_t *anchor;
            yaml_char_t *tag;
            int implicit;
            yaml_sequence_style_t style;
        } sequence_start;
        struct {
            yaml_char_t *anchor;
            yaml_char_t *tag;
            int implicit;
            yaml_mapping_style_t style;
        } mapping_start;
    } data;
    yaml_mark_t start_mark;
    yaml_mark_t end_mark;
} yaml_event_t;

/* Read handler prototype */
typedef int yaml_read_handler_t(void *data, unsigned char *buffer, size_t size,
        size_t *size_read);

/* Parser states (subset needed for struct layout) */
typedef enum yaml_parser_state_e {
    YAML_PARSE_STREAM_START_STATE,
    YAML_PARSE_IMPLICIT_DOCUMENT_START_STATE,
    YAML_PARSE_DOCUMENT_START_STATE,
    YAML_PARSE_DOCUMENT_CONTENT_STATE,
    YAML_PARSE_DOCUMENT_END_STATE,
    YAML_PARSE_BLOCK_NODE_STATE,
    YAML_PARSE_BLOCK_NODE_OR_INDENTLESS_SEQUENCE_STATE,
    YAML_PARSE_FLOW_NODE_STATE,
    YAML_PARSE_BLOCK_SEQUENCE_FIRST_ENTRY_STATE,
    YAML_PARSE_BLOCK_SEQUENCE_ENTRY_STATE,
    YAML_PARSE_INDENTLESS_SEQUENCE_ENTRY_STATE,
    YAML_PARSE_BLOCK_MAPPING_FIRST_KEY_STATE,
    YAML_PARSE_BLOCK_MAPPING_KEY_STATE,
    YAML_PARSE_BLOCK_MAPPING_VALUE_STATE,
    YAML_PARSE_FLOW_SEQUENCE_FIRST_ENTRY_STATE,
    YAML_PARSE_FLOW_SEQUENCE_ENTRY_STATE,
    YAML_PARSE_FLOW_SEQUENCE_ENTRY_MAPPING_KEY_STATE,
    YAML_PARSE_FLOW_SEQUENCE_ENTRY_MAPPING_VALUE_STATE,
    YAML_PARSE_FLOW_SEQUENCE_ENTRY_MAPPING_END_STATE,
    YAML_PARSE_FLOW_MAPPING_FIRST_KEY_STATE,
    YAML_PARSE_FLOW_MAPPING_KEY_STATE,
    YAML_PARSE_FLOW_MAPPING_VALUE_STATE,
    YAML_PARSE_FLOW_MAPPING_EMPTY_VALUE_STATE,
    YAML_PARSE_END_STATE
} yaml_parser_state_t;

/* Simple key */
typedef struct yaml_simple_key_s {
    int possible;
    int required;
    size_t token_number;
    yaml_mark_t mark;
} yaml_simple_key_t;

/* Alias data */
typedef struct yaml_alias_data_s {
    yaml_char_t *anchor;
    int index;
    yaml_mark_t mark;
} yaml_alias_data_t;

/* Document structure (forward for parser) */
typedef struct yaml_document_s yaml_document_t;
typedef struct yaml_node_s yaml_node_t;

/* Full parser structure — must match libyaml ABI exactly */
typedef struct yaml_parser_s {
    /* Error handling */
    yaml_error_type_t error;
    const char *problem;
    size_t problem_offset;
    int problem_value;
    yaml_mark_t problem_mark;
    const char *context;
    yaml_mark_t context_mark;

    /* Reader */
    yaml_read_handler_t *read_handler;
    void *read_handler_data;
    union {
        struct {
            const unsigned char *start;
            const unsigned char *end;
            const unsigned char *current;
        } string;
        void *file;
    } input;
    int eof;
    struct {
        yaml_char_t *start;
        yaml_char_t *end;
        yaml_char_t *pointer;
        yaml_char_t *last;
    } buffer;
    size_t unread;
    struct {
        unsigned char *start;
        unsigned char *end;
        unsigned char *pointer;
        unsigned char *last;
    } raw_buffer;
    yaml_encoding_t encoding;
    size_t offset;
    yaml_mark_t mark;

    /* Scanner */
    int stream_start_produced;
    int stream_end_produced;
    int flow_level;
    struct {
        yaml_token_t *start;
        yaml_token_t *end;
        yaml_token_t *head;
        yaml_token_t *tail;
    } tokens;
    size_t tokens_parsed;
    int token_available;
    struct {
        int *start;
        int *end;
        int *top;
    } indents;
    int indent;
    int simple_key_allowed;
    struct {
        yaml_simple_key_t *start;
        yaml_simple_key_t *end;
        yaml_simple_key_t *top;
    } simple_keys;

    /* Parser */
    struct {
        yaml_parser_state_t *start;
        yaml_parser_state_t *end;
        yaml_parser_state_t *top;
    } states;
    yaml_parser_state_t state;
    struct {
        yaml_mark_t *start;
        yaml_mark_t *end;
        yaml_mark_t *top;
    } marks;
    struct {
        yaml_tag_directive_t *start;
        yaml_tag_directive_t *end;
        yaml_tag_directive_t *top;
    } tag_directives;

    /* Dumper (unused but needed for struct layout) */
    struct {
        yaml_alias_data_t *start;
        yaml_alias_data_t *end;
        yaml_alias_data_t *top;
    } aliases;
    yaml_document_t *document;
} yaml_parser_t;

/* Function declarations */
int yaml_parser_initialize(yaml_parser_t *parser);
void yaml_parser_delete(yaml_parser_t *parser);
void yaml_parser_set_input_string(yaml_parser_t *parser,
        const unsigned char *input, size_t size);
int yaml_parser_parse(yaml_parser_t *parser, yaml_event_t *event);
void yaml_event_delete(yaml_event_t *event);
void yaml_token_delete(yaml_token_t *token);

#endif /* YAML_TRANSLATE_H */