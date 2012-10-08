module Puppet.NativeTypes.Group (nativeGroup) where

import Puppet.NativeTypes.Helpers
import Puppet.Interpreter.Types
import Control.Monad.Error
import qualified Data.Set as Set

nativeGroup = ("group", PuppetTypeMethods validateGroup parameterset)

-- Autorequires: If Puppet is managing the user or group that owns a file, the file resource will autorequire them. If Puppet is managing any parent directories of a file, the file resource will autorequire them.
parameterset = Set.fromList $ map fst parameterfunctions
parameterfunctions = 
    [("allowdupe"               , [string, defaultvalue "false", values ["true","false"]])
    ,("attribute_membership"    , [string, defaultvalue "minimum", values ["inclusive","minimum"]])
    ,("attributes"              , [strings])
    ,("auth_membership"         , [defaultvalue "true"])
    ,("ensure"                  , [defaultvalue "present", string, values ["present","absent"]])
    ,("gid"                     , [integer])
    ,("ia_load_module"          , [string])
    ,("members"                 , [strings])
    ,("name"                    , [nameval])
    ,("provider"                , [string, values ["aix","directoryservice","groupadd","ldap","pw","window_adsi"]])
    ,("system"                  , [string, defaultvalue "false", values ["true","false"]])
    ]

validateGroup :: PuppetTypeValidate
validateGroup = defaultValidate parameterset >=> parameterFunctions parameterfunctions

