#include <node_api.h>

NAPI_MODULE_INIT() {
  napi_value answer;
  napi_create_int32(env, 42, &answer);
  return answer;
}
