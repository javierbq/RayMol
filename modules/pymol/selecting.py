#A* -------------------------------------------------------------------
#B* This file contains source code for the PyMOL computer program
#C* Copyright (c) Schrodinger, LLC.
#D* -------------------------------------------------------------------
#E* It is unlawful to modify or remove this copyright notice.
#F* -------------------------------------------------------------------
#G* Please see the accompanying LICENSE file for further information.
#H* -------------------------------------------------------------------
#I* Additional authors of this source file include:
#-*
#-*
#-*
#Z* -------------------------------------------------------------------
from pymol.shortcut import Shortcut

if True:

    from . import selector

    cmd = __import__("sys").modules["pymol.cmd"]

    from .cmd import _cmd, \
          DEFAULT_ERROR, DEFAULT_SUCCESS, _raising, is_ok, is_error

    import pymol

    def deselect(_self=cmd):
        '''
DESCRIPTION

    "deselect" disables any and all visible selections

USAGE

    deselect

PYMOL API

    cmd.deselect()
        '''
        r = DEFAULT_SUCCESS
        arg = _self.get_names("selections",enabled_only=1)
        for a in arg:
            _self.disable(a)
        if _self._raising(r,_self): raise pymol.CmdException
        return r


    def select(name, selection="", enable=-1, quiet=1, merge=0, state=0, domain='',_self=cmd):
        '''
DESCRIPTION

    "select" creates a named atom selection from a
    selection-expression.

USAGE

    select name, selection [, enable [, quiet [, merge [, state [, domain ]]]]]

ARGUMENTS

    name = a unique name for the selection

    selection = a selection-expression

NOTES

    If a selection-expression with explicit surrounding parethenses is
    provided as the first argument, then the default selection name
    is used as the name argument.

EXAMPLES 

    select chA, chain A
    select ( resn HIS )
    select near142, resi 142 around 5

PYMOL API

    cmd.select(string name, string selection)

SEE ALSO

    delete
        '''
        with _self.lockcm:
            return _cmd.select(
                _self._COb,  #
                "" if name is None else str(name),
                str(selector.process(selection)),
                int(quiet),
                int(state) - 1,
                str(domain),
                int(enable),
                int(merge))


    def pop(name, source, enable=-1, quiet=1, _self=cmd):
        '''
DESCRIPTION

    "pop" provides a mechanism of iterating through an atom selection
    atom by atom, where each atom is sequentially assigned to the
    named selection.
    
USAGE

    pop name, source
    
EXAMPLE

    select src, name CA

    python
    while cmd.pop("tmp","src"):
        cmd.zoom("tmp",2, animate=1)
        for a in range(30):
           cmd.refresh()
           time.sleep(0.05)
    python end
    
PYMOL API

    cmd.deselect()
        '''
        r = DEFAULT_ERROR
        try:
            _self.lock(_self)
            r = _cmd.pop(_self._COb,str(name),str(source),int(quiet))
            if is_ok(r):
                enable = int(enable)
                if enable>0:
                    r = _cmd.onoff(_self._COb,str(name),1,0);
                elif enable == 0:
                    r = _cmd.onoff(_self._COb,str(name),0,0)
        finally:
            _self.unlock(r,_self)
        if _self._raising(r,_self): raise pymol.CmdException
        return r

    id_type_dict = {
        'index' : 0,
        'id'    : 1,
        'rank'  : 2,
        }

    id_type_sc = Shortcut(id_type_dict.keys())

    def select_list(name,object,id_list,state=0,mode='id',quiet=1,_self=cmd):
        '''
DESCRIPTION

    API only. Select by atom indices within a single object.

    Returns the number of selected atoms.

ARGUMENTS

    name = str: a unique name for the selection

    object = str: object name

    id_list = list of integers: ID, index, or rank list.

    state = int: object state, to limit selection to atoms which have
    coordinates in that state (-1 = current, 0 = ignore) {default: 0}

    mode = id|index|rank: {default: id}
        '''
        #
        mode = id_type_dict[id_type_sc.auto_err(mode,'identifier type')]
        with _self.lockcm:
            return _cmd.select_list(_self._COb, name, object, id_list,
                                    int(state) - 1, int(mode), int(quiet))

    box_mode_sc = Shortcut(['replace', 'add', 'subtract'])

    def box_select(x1, y1, x2, y2, name="sele", mode="replace",
                   selection="all", state=-1, quiet=1, _self=cmd):
        '''
DESCRIPTION

    "box_select" selects every visible atom whose projection on screen falls
    inside a rectangle given in viewport pixels -- the command form of the
    interactive rubber-band Box Select tool.

    Only atoms that are actually DRAWN are considered, atoms outside the clip
    slab are skipped, and coordinates come from the displayed state, so a box
    catches what the user can see and nothing behind it.

    Returns the number of atoms the box caught.

USAGE

    box_select x1, y1, x2, y2 [, name [, mode [, selection [, state ]]]]

ARGUMENTS

    x1, y1, x2, y2 = float: opposite corners of the rectangle, in viewport
    pixels with the ORIGIN AT THE BOTTOM-LEFT (the same convention as
    cmd.get_viewport). Any corner order works.

    name = str: selection to write {default: sele}

    mode = replace|add|subtract: how to combine the box contents with what
    "name" already holds {default: replace}

    selection = str: narrows the candidate atoms before projection
    {default: all}

    state = int: state to take coordinates from, -1 = displayed state
    {default: -1}

EXAMPLES

    box_select 100, 100, 400, 300
    box_select 100, 100, 400, 300, mode=add
    box_select 0, 0, 640, 480, name=front, selection=polymer

PYMOL API

    cmd.box_select(float x1, float y1, float x2, float y2, string name,
                   string mode, string selection, int state)

SEE ALSO

    select, get_viewport
        '''
        from pymol import metal_pick
        mode = box_mode_sc.auto_err(mode, 'box mode')
        # _cmd.get_viewport directly, not cmd.get_viewport: the wrapper emits a
        # "viewport W, H" line into an open log file, and reading the size to
        # convert pixels is no reason to pollute the user's log.
        with _self.lockcm:
            width, height = _cmd.get_viewport(_self._COb)
        if width <= 0 or height <= 0:
            raise pymol.CmdException("viewport has no size")
        n = metal_pick.box_select_ndc(
            2.0 * float(x1) / width - 1.0, 2.0 * float(y1) / height - 1.0,
            2.0 * float(x2) / width - 1.0, 2.0 * float(y2) / height - 1.0,
            float(width) / float(height), name=str(name), mode=mode,
            selection=str(selection), state=int(state))
        if not int(quiet):
            print(' box_select: %d atoms selected as "%s".' % (n, name))
        return n

    def indicate(selection="(all)",_self=cmd):
        '''
DESCRIPTION

    "indicate" shows a visual representation of an atom selection.

USAGE

    indicate (selection)

PYMOL API

    cmd.count(string selection)

        '''
        r = DEFAULT_ERROR
        # preprocess selection
        selection = selector.process(selection)
        #
        try:
            _self.lock(_self)
            r = _cmd.select(_self._COb,"indicate","("+str(selection)+")",1,-1,'')
            if is_error(r):
                _self.delete("indicate")
            else:
                _self.enable("indicate")
        finally:
            _self.unlock(r,_self)
        if _self._raising(r,_self): raise pymol.CmdException
        return r

    def objsele_state_iter(selection, state=0, _self=cmd):
        '''
DESCRIPTION

    API only. Get (object-specific-selection, object-state) tuples for all
    objects in selection.
        '''
        for oname in _self.get_object_list('(' + selection + ')'):
            osele = '(%s) & ?%s' % (selection, oname)
            if state < 0:
                first = last = _self.get_object_state(oname)
            else:
                first = last = state
            if first == 0:
                first = 1
                last = _self.count_states('%' + oname)
            for ostate in range(first, last + 1):
                yield osele, ostate
