"""Hooks de Schemathesis para el test de contrato de notifications.

Los ids de servidor y canal generados al azar nunca existen, asi que las rutas de
settings solo verian 403/404. Este hook reemplaza, en la mitad de los casos (de
forma determinista, segun el valor generado), el id por el del servidor y el canal
que siembra seed.js. La otra mitad sigue con ids al azar y cubre los errores.
"""

import schemathesis

IDS = {
    "server_id": "00000000-0000-4000-8000-0000000000a1",
    "channel_id": "00000000-0000-4000-8000-0000000000b1",
}


@schemathesis.hook
def map_path_parameters(context, path_parameters):
    if path_parameters is None:
        return path_parameters
    for name, seeded in IDS.items():
        value = path_parameters.get(name)
        if isinstance(value, str) and sum(map(ord, value)) % 2 == 0:
            path_parameters[name] = seeded
    return path_parameters
