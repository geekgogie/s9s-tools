/* 
 * Copyright (C) 2011-2016 severalnines.com
 */
#pragma once

#include "S9sVariant"
#include "S9sMap"
#include "S9sVector"
#include "S9sString"
#include "S9sParseContext"

class S9sVariantList;

class S9sVariantMap : public S9sMap<S9sString, S9sVariant>
{
    public:
        S9sVariantMap() : S9sMap<S9sString, S9sVariant>() {};
        virtual ~S9sVariantMap() {};

        S9sVector<S9sString> keys() const;

        const S9sVariant &valueByPath(const S9sString &path) const;
        const S9sVariant &valueByPath(S9sVariantList path) const;

        bool parse(const char *source);
        S9sString toString() const;
        bool parseAssignments(const S9sString &input);
        bool isSubSet(const S9sVariantMap &superSet) const;

    protected:
        static const S9sVariant sm_invalid;

    private:
        S9sString toString(
                int                  depth, 
                const S9sVariantMap &variantMap) const;

        S9sString toString (
                int                   depth,
                const S9sVariantList &theList) const;

        S9sString toString (
                int               depth,
                const S9sVariant &value) const;

        S9sString indent(int depth) const;
        S9sString quote(const S9sString &s) const;
};


