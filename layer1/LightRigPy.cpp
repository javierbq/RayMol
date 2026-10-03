/*
 * Python conversions of the light rig (#611). See LightRigPy.h.
 */

#include "LightRigPy.h"

#ifndef _PYMOL_NOPY

#include <cmath>
#include <initializer_list>
#include <string>
#include <utility>
#include <vector>

using pymol::Light;
using pymol::LightField;
using pymol::LightKind;
using pymol::LightRig;
using pymol::LightScope;
using pymol::LightValue;

namespace
{

const char* scopeName(LightScope scope)
{
  switch (scope) {
  case LightScope::Rig:
    return "rig";
  case LightScope::Air:
    return "air";
  case LightScope::Light:
    return "light";
  }
  return "";
}

/* ---- to Python -------------------------------------------------------- */

PyObject* pyString(const std::string& s)
{
  return PyUnicode_DecodeUTF8(s.data(), Py_ssize_t(s.size()), "replace");
}

PyObject* pyVec3(const double* v)
{
  return Py_BuildValue("[ddd]", v[0], v[1], v[2]);
}

PyObject* pyNone()
{
  Py_RETURN_NONE;
}

PyObject* pyVec3(const glm::vec3& v)
{
  return Py_BuildValue("[ddd]", double(v.x), double(v.y), double(v.z));
}

/// One field's value as a Python object (new reference, nullptr on error).
PyObject* valueToPy(const LightField& field, const LightValue& value)
{
  if (value.unset)
    Py_RETURN_NONE;
  const double v = value.num[0];
  switch (field.kind) {
  case LightKind::Bool:
    return PyBool_FromLong(v != 0.0);
  case LightKind::Int:
    return PyLong_FromLong(long(v));
  case LightKind::Float:
  case LightKind::Angle:
    return PyFloat_FromDouble(v);
  case LightKind::Vec3:
    return pyVec3(value.num);
  case LightKind::Str:
  case LightKind::Name:
    return pyString(value.str);
  case LightKind::Anchor:
  case LightKind::Aim:
    return PyUnicode_FromString(pymol::LightChoiceName(field.kind, int(v)));
  }
  Py_RETURN_NONE;
}

/// d[key] = value, stealing `value`. False (with a Python error) on failure.
bool setItem(PyObject* d, const char* key, PyObject* value)
{
  if (!value)
    return false;
  int rc = PyDict_SetItemString(d, key, value);
  Py_DECREF(value);
  return rc == 0;
}

template <typename Source>
bool putFields(PyObject* d, LightScope scope, const Source& source)
{
  for (const auto& field : pymol::LightRigFields()) {
    if (field.scope != scope)
      continue;
    if (!setItem(d, field.name, valueToPy(field, LightFieldGet(source, field))))
      return false;
  }
  return true;
}

/* ---- from Python ------------------------------------------------------ */

std::string typeName(PyObject* o)
{
  return Py_TYPE(o)->tp_name;
}

std::string reprOf(PyObject* o)
{
  unique_PyObject_ptr repr(PyObject_Repr(o));
  if (!repr) {
    PyErr_Clear();
    return typeName(o);
  }
  const char* s = PyUnicode_AsUTF8(repr.get());
  if (!s) {
    PyErr_Clear();
    return typeName(o);
  }
  return s;
}

/// A Python int or float (not a bool) as a double.
bool pyNumber(PyObject* o, double& out)
{
  if (PyBool_Check(o) || !(PyFloat_Check(o) || PyLong_Check(o)))
    return false;
  out = PyFloat_AsDouble(o);
  if (out == -1.0 && PyErr_Occurred()) {
    PyErr_Clear(); // an int too large for a double
    out = HUGE_VAL;
  }
  return true;
}

pymol::Result<double> number(
    const LightField& field, PyObject* o, const std::string& where)
{
  double v;
  if (!pyNumber(o, v)) {
    return pymol::make_error(where, "'", field.name, "' must be a number, got ",
        typeName(o));
  }
  if (!std::isfinite(v)) {
    return pymol::make_error(
        where, "'", field.name, "' must be finite, got ", reprOf(o));
  }
  return v;
}

/// One field's value from a Python object, strictly typed.
pymol::Result<LightValue> valueFromPy(
    const LightField& field, PyObject* o, const std::string& where)
{
  LightValue value;
  if (o == Py_None && field.optional) {
    value.unset = true;
    return value;
  }

  switch (field.kind) {
  case LightKind::Bool: {
    // True/False, or the ints 0/1 (the session list stores 0|1)
    long b = -1;
    if (PyBool_Check(o) || PyLong_Check(o)) {
      b = PyLong_AsLong(o);
      if (b == -1 && PyErr_Occurred())
        PyErr_Clear();
    }
    if (b != 0 && b != 1) {
      return pymol::make_error(where, "'", field.name,
          "' must be True or False, got ", reprOf(o));
    }
    value.num[0] = double(b);
    return value;
  }
  case LightKind::Int: {
    if (PyBool_Check(o) || !PyLong_Check(o)) {
      return pymol::make_error(where, "'", field.name,
          "' must be an int, got ", typeName(o));
    }
    auto v = number(field, o, where);
    p_return_if_error(v);
    value.num[0] = *v;
    return value;
  }
  case LightKind::Float:
  case LightKind::Angle: {
    auto v = number(field, o, where);
    p_return_if_error(v);
    value.num[0] = *v;
    return value;
  }
  case LightKind::Vec3: {
    const bool seq = (PyList_Check(o) || PyTuple_Check(o)) &&
                     PySequence_Size(o) == 3;
    if (!seq) {
      return pymol::make_error(where, "'", field.name,
          "' must be a list of 3 numbers", field.optional ? " or None" : "",
          ", got ", reprOf(o));
    }
    for (int i = 0; i < 3; ++i) {
      PyObject* item = PySequence_Fast_GET_ITEM(o, i); // list or tuple
      auto v = number(field, item, where);
      p_return_if_error(v);
      value.num[i] = *v;
    }
    return value;
  }
  case LightKind::Str:
  case LightKind::Name: {
    if (!PyUnicode_Check(o)) {
      return pymol::make_error(where, "'", field.name,
          "' must be a string, got ", typeName(o));
    }
    Py_ssize_t len = 0;
    const char* s = PyUnicode_AsUTF8AndSize(o, &len);
    if (!s) {
      PyErr_Clear();
      return pymol::make_error(
          where, "'", field.name, "' is not valid text");
    }
    value.str.assign(s, size_t(len));
    return value;
  }
  case LightKind::Anchor:
  case LightKind::Aim: {
    int index = -1;
    if (PyUnicode_Check(o)) {
      const char* s = PyUnicode_AsUTF8(o);
      if (s)
        index = pymol::LightChoiceIndex(field.kind, s);
      else
        PyErr_Clear();
    }
    if (index < 0) {
      return pymol::make_error(where, "'", field.name, "' must be '",
          pymol::LightChoiceName(field.kind, 0), "' or '",
          pymol::LightChoiceName(field.kind, 1), "', got ", reprOf(o));
    }
    value.num[0] = index;
    return value;
  }
  }
  return pymol::make_error(where, "'", field.name, "': unsupported kind");
}

/// Every key of `d` is a string naming a field of `scope` or one of `extra`.
pymol::Result<> checkKeys(PyObject* d, LightScope scope,
    std::initializer_list<const char*> extra, const std::string& where)
{
  PyObject *key, *item;
  Py_ssize_t pos = 0;
  while (PyDict_Next(d, &pos, &key, &item)) {
    if (!PyUnicode_Check(key)) {
      return pymol::make_error(
          where, "keys must be strings, got ", reprOf(key));
    }
    const char* k = PyUnicode_AsUTF8(key);
    if (!k) {
      PyErr_Clear();
      return pymol::make_error(where, "keys must be valid text");
    }
    bool known = pymol::LightRigFindField(scope, k) != nullptr;
    for (const char* name : extra)
      known = known || std::string(k) == name;
    if (!known)
      return pymol::make_error(where, "unknown key '", k, "'");
  }
  return {};
}

/// Put every field of `scope` present in `d` into `target`.
template <typename Target>
pymol::Result<> takeFields(
    PyObject* d, LightScope scope, Target& target, const std::string& where)
{
  for (const auto& field : pymol::LightRigFields()) {
    if (field.scope != scope)
      continue;
    PyObject* item = PyDict_GetItemString(d, field.name); // borrowed
    if (!item)
      continue;
    auto value = valueFromPy(field, item, where);
    p_return_if_error(value);
    LightFieldPut(target, field, *value);
  }
  return {};
}

pymol::Result<Light> lightFromPy(PyObject* d, size_t index, bool& named)
{
  std::string where = "light " + std::to_string(index);
  if (!PyDict_Check(d)) {
    return pymol::make_error(where, " must be a dict, got ", typeName(d));
  }
  PyObject* name = PyDict_GetItemString(d, "name");
  if (name && PyUnicode_Check(name)) {
    if (const char* s = PyUnicode_AsUTF8(name))
      where += " ('" + std::string(s) + "')";
    else
      PyErr_Clear();
  }
  where += ": ";

  auto keys = checkKeys(d, LightScope::Light, {}, where);
  p_return_if_error(keys);

  Light light;
  auto taken = takeFields(d, LightScope::Light, light, where);
  p_return_if_error(taken);

  named = name != nullptr;
  if (light.anchor == pymol::LightAnchor::Pinned &&
      !PyDict_GetItemString(d, "position")) {
    return pymol::make_error(where, "a pinned light needs 'position'");
  }
  return light;
}

} // namespace

PyObject* LightRigAsPyDict(const LightRig& rig)
{
  unique_PyObject_ptr dict(PyDict_New());
  if (!dict)
    return nullptr;
  if (!setItem(dict.get(), "version", PyLong_FromLong(pymol::kLightRigVersion)))
    return nullptr;
  if (!putFields(dict.get(), LightScope::Rig, rig))
    return nullptr;

  PyObject* air = PyDict_New();
  if (!air || !putFields(air, LightScope::Air, rig)) {
    Py_XDECREF(air);
    return nullptr;
  }
  if (!setItem(dict.get(), "air", air))
    return nullptr;

  PyObject* lights = PyList_New(Py_ssize_t(rig.lights.size()));
  if (!lights)
    return nullptr;
  for (size_t i = 0; i < rig.lights.size(); ++i) {
    PyObject* d = PyDict_New();
    if (!d || !putFields(d, LightScope::Light, rig.lights[i])) {
      Py_XDECREF(d);
      Py_DECREF(lights);
      return nullptr;
    }
    PyList_SET_ITEM(lights, Py_ssize_t(i), d); // steals d
  }
  if (!setItem(dict.get(), "lights", lights))
    return nullptr;

  return dict.release();
}

pymol::Result<LightRig> LightRigFromPyDict(PyObject* obj)
{
  if (!PyDict_Check(obj)) {
    return pymol::make_error(
        "expected a dict (or None), got ", typeName(obj));
  }

  auto keys = checkKeys(obj, LightScope::Rig, {"version", "air", "lights"}, "");
  p_return_if_error(keys);

  if (PyObject* version = PyDict_GetItemString(obj, "version")) {
    long v = -1;
    if (PyLong_Check(version) && !PyBool_Check(version)) {
      v = PyLong_AsLong(version);
      if (v == -1 && PyErr_Occurred())
        PyErr_Clear();
    } else {
      return pymol::make_error(
          "'version' must be an int, got ", typeName(version));
    }
    if (v > pymol::kLightRigVersion) {
      return pymol::make_error("'version' ", reprOf(version),
          " is newer than this build reads (", pymol::kLightRigVersion, ")");
    }
    if (v < 1) {
      return pymol::make_error("'version' ", reprOf(version),
          " is not a light rig version (1 to ", pymol::kLightRigVersion, ")");
    }
  }

  LightRig rig;
  auto taken = takeFields(obj, LightScope::Rig, rig, "");
  p_return_if_error(taken);

  if (PyObject* air = PyDict_GetItemString(obj, "air")) {
    if (!PyDict_Check(air)) {
      return pymol::make_error("'air' must be a dict, got ", typeName(air));
    }
    auto airKeys = checkKeys(air, LightScope::Air, {}, "air: ");
    p_return_if_error(airKeys);
    auto airTaken = takeFields(air, LightScope::Air, rig, "air: ");
    p_return_if_error(airTaken);
  }

  if (PyObject* lights = PyDict_GetItemString(obj, "lights")) {
    if (!PyList_Check(lights) && !PyTuple_Check(lights)) {
      return pymol::make_error(
          "'lights' must be a list, got ", typeName(lights));
    }
    const Py_ssize_t n = PySequence_Size(lights);
    if (n > pymol::kLightRigMaxLights) {
      return pymol::make_error("at most ", pymol::kLightRigMaxLights,
          " lights (got ", long(n), ")");
    }
    std::vector<bool> named;
    for (Py_ssize_t i = 0; i < n; ++i) {
      bool hasName = false;
      auto light = lightFromPy(
          PySequence_Fast_GET_ITEM(lights, i), size_t(i), hasName);
      p_return_if_error(light);
      rig.lights.push_back(std::move(*light));
      named.push_back(hasName);
    }
    // Unnamed lights take the first default names that no light uses.
    std::vector<std::string> names;
    for (size_t i = 0; i < rig.lights.size(); ++i) {
      if (named[i])
        names.push_back(rig.lights[i].name);
    }
    for (size_t i = 0; i < rig.lights.size(); ++i) {
      if (!named[i]) {
        rig.lights[i].name = pymol::LightRigNextName(names);
        names.push_back(rig.lights[i].name);
      }
    }
  }

  return rig;
}

PyObject* LightValueAsPy(const LightField& field, const LightValue& value)
{
  return valueToPy(field, value);
}

PyObject* LightRigEyeAsPyDict(
    const LightRig& rig, const pymol::LightRigEye& eye)
{
  unique_PyObject_ptr dict(PyDict_New());
  if (!dict)
    return nullptr;
  if (!setItem(dict.get(), "enabled", PyBool_FromLong(eye.enabled)))
    return nullptr;
  if (eye.hasFrame) {
    if (!setItem(dict.get(), "centre", pyVec3(eye.centre)) ||
        !setItem(dict.get(), "size", PyFloat_FromDouble(eye.size)))
      return nullptr;
  } else {
    if (!setItem(dict.get(), "centre", pyNone()) ||
        !setItem(dict.get(), "size", pyNone()))
      return nullptr;
  }

  PyObject* lights = PyList_New(0);
  if (!setItem(dict.get(), "lights", lights))
    return nullptr;
  for (size_t i = 0; i < eye.lights.size() && i < rig.lights.size(); ++i) {
    const auto& e = eye.lights[i];
    unique_PyObject_ptr d(PyDict_New());
    if (!d)
      return nullptr;
    const bool ok =
        setItem(d.get(), "name", pyString(rig.lights[i].name)) &&
        setItem(d.get(), "anchor",
            PyUnicode_FromString(pymol::LightChoiceName(
                LightKind::Anchor, static_cast<int>(e.anchor)))) &&
        setItem(d.get(), "aim",
            PyUnicode_FromString(pymol::LightChoiceName(
                LightKind::Aim, static_cast<int>(e.aim)))) &&
        setItem(d.get(), "position", pyVec3(e.position)) &&
        setItem(d.get(), "target", pyVec3(e.target)) &&
        setItem(d.get(), "direction", pyVec3(e.direction)) &&
        setItem(d.get(), "aim_distance", PyFloat_FromDouble(e.aimDistance)) &&
        setItem(d.get(), "cos_outer", PyFloat_FromDouble(e.cosOuter)) &&
        setItem(d.get(), "cos_inner", PyFloat_FromDouble(e.cosInner)) &&
        setItem(d.get(), "orbit", PyFloat_FromDouble(e.orbit)) &&
        setItem(d.get(), "pitch", PyFloat_FromDouble(e.pitch)) &&
        setItem(d.get(), "radius", PyFloat_FromDouble(e.radius)) &&
        setItem(d.get(), "shadow", PyBool_FromLong(e.shadow)) &&
        setItem(d.get(), "outline", PyBool_FromLong(e.outline));
    if (!ok || PyList_Append(lights, d.get()) != 0) // lights is borrowed
      return nullptr;
  }
  return dict.release();
}

pymol::Result<glm::dmat4> LightMatrixFromPy(PyObject* obj)
{
  const bool seq = (PyList_Check(obj) || PyTuple_Check(obj)) &&
                   PySequence_Size(obj) == 16;
  if (!seq) {
    return pymol::make_error(
        "matrix must be 16 numbers (column-major) or None, got ", reprOf(obj));
  }
  glm::dmat4 m(1.0);
  for (int i = 0; i < 16; ++i) {
    double v;
    PyObject* item = PySequence_Fast_GET_ITEM(obj, i); // list or tuple
    if (!pyNumber(item, v) || !std::isfinite(v)) {
      return pymol::make_error(
          "matrix item ", i, " must be a finite number, got ", reprOf(item));
    }
    m[i / 4][i % 4] = v; // column i / 4, row i % 4
  }
  return m;
}

pymol::Result<> LightSetValueFromPy(PyObject* obj, double v[3], int& n)
{
  if (PyBool_Check(obj)) {
    v[0] = obj == Py_True ? 1.0 : 0.0;
    n = 1;
    return {};
  }
  if (pyNumber(obj, v[0])) {
    n = 1;
    return {};
  }
  if ((PyList_Check(obj) || PyTuple_Check(obj)) && PySequence_Size(obj) == 3) {
    for (int i = 0; i < 3; ++i) {
      PyObject* item = PySequence_Fast_GET_ITEM(obj, i); // list or tuple
      if (!pyNumber(item, v[i])) {
        return pymol::make_error(
            "value item ", i, " must be a number, got ", reprOf(item));
      }
    }
    n = 3;
    return {};
  }
  return pymol::make_error(
      "value must be a number or a list of 3 numbers, got ", reprOf(obj));
}

PyObject* LightFieldsAsPyList()
{
  const LightRig rig;
  const Light light;
  const auto& fields = pymol::LightRigFields();
  PyObject* list = PyList_New(Py_ssize_t(fields.size()));
  if (!list)
    return nullptr;
  for (size_t i = 0; i < fields.size(); ++i) {
    const auto& field = fields[i];
    PyObject* def = nullptr;
    if (field.kind == LightKind::Name) {
      def = Py_None; // assigned: key, fill, rim, light4, ...
      Py_INCREF(def);
    } else if (field.scope == LightScope::Light) {
      def = valueToPy(field, LightFieldGet(light, field));
    } else {
      def = valueToPy(field, LightFieldGet(rig, field));
    }
    PyObject *lo, *hi;
    if (!field.bounded) {
      lo = Py_None;
      hi = Py_None;
      Py_INCREF(lo);
      Py_INCREF(hi);
    } else if (field.kind == LightKind::Int) {
      lo = PyLong_FromLong(long(field.lo));
      hi = PyLong_FromLong(long(field.hi));
    } else {
      lo = PyFloat_FromDouble(field.lo);
      hi = PyFloat_FromDouble(field.hi);
    }
    PyObject* entry = (def && lo && hi)
                          ? Py_BuildValue("(sssOOO)", scopeName(field.scope),
                                field.name, pymol::LightKindName(field.kind),
                                def, lo, hi)
                          : nullptr;
    Py_XDECREF(def);
    Py_XDECREF(lo);
    Py_XDECREF(hi);
    if (!entry) {
      Py_DECREF(list);
      return nullptr;
    }
    PyList_SET_ITEM(list, Py_ssize_t(i), entry);
  }
  return list;
}

#endif
