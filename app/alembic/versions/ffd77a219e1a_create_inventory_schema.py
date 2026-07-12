"""create inventory schema

Revision ID: ffd77a219e1a
Revises: 51cb7d387127
Create Date: 2026-07-08 07:42:26.088937

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'ffd77a219e1a'
down_revision: Union[str, None] = '51cb7d387127'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with open(f"alembic/sql/{revision}/up.sql", encoding="utf-8") as file:
        op.execute(file.read())


def downgrade() -> None:
    with open(f"alembic/sql/{revision}/down.sql", encoding="utf-8") as file:
        op.execute(file.read())