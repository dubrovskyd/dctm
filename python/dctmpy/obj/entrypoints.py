#  Copyright (c) 2013 Andrey B. Panfilov <andrew@panfilov.tel>
#
#  See main module for license.
#

from dctmpy.obj.typedobject import TypedObject


class EntryPoints(TypedObject):
    def __init__(self, **kwargs):
        self.__methods = None
        super(EntryPoints, self).__init__(**dict(
            kwargs,
            **{'serializationversion': 0}
        ))

    def deserialize(self, message=None):
        super(EntryPoints, self).deserialize(message)
        if len(self) > 0:
            names = self['name']
            poss = self['pos']
            self.__methods = dict((names[i], poss[i]) for i in range(0, len(names)))

    def methods(self):
        return self.__methods

    def __getattr__(self, name):
        if self.__methods is not None:
            return self.__methods[name]
        else:
            return super(EntryPoints, self).__getattr__(name)

    def __setattr__(self, name, value):
        super(EntryPoints, self).__setattr__(name, value)


