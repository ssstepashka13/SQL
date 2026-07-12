"""create cities and link warehouses

Revision ID: 51cb7d387127
Revises: 9f30e47c51a6
Create Date: 2026-07-08 07:42:25.934351

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '51cb7d387127'
down_revision: Union[str, None] = '9f30e47c51a6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with open(f"alembic/sql/{revision}/up.sql", encoding="utf-8") as file:
        op.execute(file.read())


def downgrade() -> None:
    with open(f"alembic/sql/{revision}/down.sql", encoding="utf-8") as file:
        op.execute(file.read())